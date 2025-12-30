# Constellation Project VMs module
#
# This module provides isolated development environments using Debian testing VMs
# with native Docker support, Nix, Claude Code CLI, and Tailscale SSH access.
#
# Architecture:
#   /var/lib/project-vms/
#   ├── base/debian-testing.qcow2  (shared backing file)
#   ├── myapp/
#   │   ├── disk.qcow2     (COW overlay for system)
#   │   └── project.qcow2  (persistent /home/dev/project)
#   └── webapp/
#       └── ...
#
# Each VM:
# - Uses a COW overlay disk for fast creation and efficient storage
# - Has a separate project disk for persistent data
# - Gets provisioned via cloud-init with Docker, Nix, Tailscale, Claude Code
# - Is accessible via Tailscale SSH (project-<name>.bat-boa.ts.net)
#
# Usage:
#   constellation.projectVms = {
#     enable = true;
#     tailscaleAuthKeyFile = config.sops.secrets.tailscale-project-vm-key.path;
#     sshPublicKey = "ssh-ed25519 AAAA...";
#   };
#
# Then use the CLI:
#   project-vm create myapp
#   project-vm start myapp
#   project-vm ssh myapp
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.projectVms;

  # Debian cloud image URL and filename
  debianImageUrl = "https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-trixie-genericcloud-amd64-daily.qcow2";
  debianImageName = "debian-testing.qcow2";

  # Type for a single project VM configuration (for future declarative projects)
  projectOpts = {
    name,
    config,
    ...
  }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable this project VM.";
      };

      memory = mkOption {
        type = types.int;
        default = cfg.defaultMemory;
        description = "Memory in MB for this VM.";
      };

      cpus = mkOption {
        type = types.int;
        default = cfg.defaultCpus;
        description = "Number of CPUs for this VM.";
      };

      diskSize = mkOption {
        type = types.str;
        default = cfg.defaultDiskSize;
        description = "Size of the project disk (e.g., '50G').";
      };

      tailscaleHostname = mkOption {
        type = types.str;
        default = "project-${name}";
        description = "Hostname for this VM in Tailscale network.";
      };
    };
  };

  # Create the project-vm CLI script
  projectVmCli = pkgs.writeShellApplication {
    name = "project-vm";
    runtimeInputs = with pkgs; [
      libvirt
      qemu
      cloud-utils
      coreutils
      gawk
      gnused
      gnugrep
      openssh
      jq
    ];
    text = ''
      set -euo pipefail

      STORAGE_DIR="${cfg.storageDir}"
      BASE_IMAGE="$STORAGE_DIR/base/${debianImageName}"
      DEFAULT_MEMORY="${toString cfg.defaultMemory}"
      DEFAULT_CPUS="${toString cfg.defaultCpus}"
      DEFAULT_DISK="${cfg.defaultDiskSize}"
      SSH_PUBLIC_KEY="${cfg.sshPublicKey}"
      TAILSCALE_AUTH_KEY_FILE="${cfg.tailscaleAuthKeyFile}"

      usage() {
        echo "Usage: project-vm <command> [args]"
        echo ""
        echo "Commands:"
        echo "  create <name> [memory_mb] [cpus] [disk_size]  Create a new project VM"
        echo "  start <name>                                   Start a project VM"
        echo "  stop <name>                                    Stop a project VM (with timeout)"
        echo "  destroy <name> [--keep-data]                   Remove VM and disks"
        echo "  ssh <name>                                     SSH into VM via Tailscale"
        echo "  list                                           List all project VMs"
        echo "  status <name>                                  Show VM status and details"
        echo "  console <name>                                 Attach to VM console"
        echo ""
        echo "Options:"
        echo "  --keep-data  Keep the project data disk when destroying a VM"
        echo ""
        echo "Examples:"
        echo "  project-vm create myapp 16384 8 100G"
        echo "  project-vm start myapp"
        echo "  project-vm ssh myapp"
        echo "  project-vm destroy myapp --keep-data"
        exit 1
      }

      check_base_image() {
        if [[ ! -f "$BASE_IMAGE" ]]; then
          echo "Error: Base image not found at $BASE_IMAGE"
          echo "Run: sudo systemctl start project-vm-base"
          exit 1
        fi
      }

      # Generate cloud-init user-data
      generate_cloud_init() {
        local name="$1"
        local project_dir="$STORAGE_DIR/$name"
        local tailscale_key
        tailscale_key=$(cat "$TAILSCALE_AUTH_KEY_FILE")

        mkdir -p "$project_dir"

        # Create meta-data
        cat > "$project_dir/meta-data" << EOF
      instance-id: project-$name
      local-hostname: project-$name
      EOF

        # Create user-data with cloud-init configuration
        cat > "$project_dir/user-data" << EOF
      #cloud-config
      users:
        - name: dev
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: /bin/bash
          ssh_authorized_keys:
            - $SSH_PUBLIC_KEY

      package_update: true
      package_upgrade: true
      packages:
        - docker.io
        - docker-compose
        - git
        - curl
        - vim
        - tmux
        - jq
        - htop
        - build-essential
        - xz-utils

      write_files:
        - path: /etc/docker/daemon.json
          content: |
            {
              "storage-driver": "overlay2",
              "log-driver": "json-file",
              "log-opts": {
                "max-size": "10m",
                "max-file": "3"
              }
            }

      runcmd:
        # Add dev user to docker group
        - usermod -aG docker dev

        # Mount project disk
        - mkdir -p /home/dev/project
        - |
          if ! blkid /dev/vdb | grep -q ext4; then
            mkfs.ext4 -L project /dev/vdb
          fi
        - mount /dev/vdb /home/dev/project
        - echo '/dev/vdb /home/dev/project ext4 defaults 0 2' >> /etc/fstab
        - chown -R dev:dev /home/dev/project

        # Install Nix (multi-user)
        - |
          curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
          echo '. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' >> /home/dev/.bashrc

        # Install Tailscale
        - curl -fsSL https://tailscale.com/install.sh | sh
        - tailscale up --authkey=$tailscale_key --hostname=project-$name --ssh

        # Install Claude Code CLI via npm
        - |
          curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
          apt-get install -y nodejs
          npm install -g @anthropic-ai/claude-code

      final_message: "Project VM '$name' is ready! Connect via: ssh dev@project-$name.bat-boa.ts.net"
      EOF

        # Create cloud-init ISO
        cloud-localds "$project_dir/cloud-init.iso" "$project_dir/user-data" "$project_dir/meta-data"
      }

      create_vm() {
        local name="$1"
        local memory="''${2:-$DEFAULT_MEMORY}"
        local cpus="''${3:-$DEFAULT_CPUS}"
        local disk_size="''${4:-$DEFAULT_DISK}"
        local project_dir="$STORAGE_DIR/$name"

        check_base_image

        if virsh dominfo "project-$name" &>/dev/null; then
          echo "Error: VM 'project-$name' already exists"
          exit 1
        fi

        echo "Creating project VM: $name"
        echo "  Memory: ''${memory}MB"
        echo "  CPUs: $cpus"
        echo "  Project disk: $disk_size"

        mkdir -p "$project_dir"

        # Create COW overlay disk
        echo "Creating COW overlay disk..."
        qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$project_dir/disk.qcow2"

        # Create project data disk
        echo "Creating project data disk..."
        qemu-img create -f qcow2 "$project_dir/project.qcow2" "$disk_size"

        # Generate cloud-init ISO
        echo "Generating cloud-init configuration..."
        generate_cloud_init "$name"

        # Create libvirt domain XML
        cat > "$project_dir/domain.xml" << EOF
      <domain type='kvm'>
        <name>project-$name</name>
        <memory unit='MiB'>$memory</memory>
        <vcpu>$cpus</vcpu>
        <os>
          <type arch='x86_64'>hvm</type>
          <boot dev='hd'/>
        </os>
        <features>
          <acpi/>
          <apic/>
        </features>
        <cpu mode='host-passthrough'/>
        <devices>
          <disk type='file' device='disk'>
            <driver name='qemu' type='qcow2'/>
            <source file='$project_dir/disk.qcow2'/>
            <target dev='vda' bus='virtio'/>
          </disk>
          <disk type='file' device='disk'>
            <driver name='qemu' type='qcow2'/>
            <source file='$project_dir/project.qcow2'/>
            <target dev='vdb' bus='virtio'/>
          </disk>
          <disk type='file' device='cdrom'>
            <driver name='qemu' type='raw'/>
            <source file='$project_dir/cloud-init.iso'/>
            <target dev='sda' bus='sata'/>
            <readonly/>
          </disk>
          <interface type='network'>
            <source network='default'/>
            <model type='virtio'/>
          </interface>
          <console type='pty'>
            <target type='serial' port='0'/>
          </console>
          <graphics type='vnc' port='-1' autoport='yes'/>
        </devices>
      </domain>
      EOF

        # Define the VM
        virsh define "$project_dir/domain.xml"
        echo ""
        echo "VM 'project-$name' created successfully!"
        echo "Start it with: project-vm start $name"
      }

      start_vm() {
        local name="$1"
        if ! virsh dominfo "project-$name" &>/dev/null; then
          echo "Error: VM 'project-$name' does not exist"
          exit 1
        fi
        echo "Starting VM 'project-$name'..."
        virsh start "project-$name"
        echo ""
        echo "VM is starting. It may take a few minutes for cloud-init to complete."
        echo "Once ready, connect with: project-vm ssh $name"
      }

      stop_vm() {
        local name="$1"
        if ! virsh dominfo "project-$name" &>/dev/null; then
          echo "Error: VM 'project-$name' does not exist"
          exit 1
        fi

        # Check if VM is running
        local state
        state=$(virsh domstate "project-$name" 2>/dev/null || echo "unknown")
        if [[ "$state" != "running" ]]; then
          echo "VM 'project-$name' is not running (state: $state)"
          exit 0
        fi

        echo "Stopping VM 'project-$name'..."
        virsh shutdown "project-$name"

        # Wait for graceful shutdown with timeout
        local timeout=60
        local elapsed=0
        echo "Waiting for graceful shutdown (timeout: ''${timeout}s)..."
        while [[ $elapsed -lt $timeout ]]; do
          state=$(virsh domstate "project-$name" 2>/dev/null || echo "unknown")
          if [[ "$state" != "running" ]]; then
            echo "VM stopped gracefully."
            exit 0
          fi
          sleep 2
          elapsed=$((elapsed + 2))
        done

        echo "Graceful shutdown timed out, forcing stop..."
        virsh destroy "project-$name"
        echo "VM force-stopped."
      }

      destroy_vm() {
        local name="$1"
        local keep_data=false
        local project_dir="$STORAGE_DIR/$name"

        # Parse --keep-data flag
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --keep-data)
              keep_data=true
              shift
              ;;
            *)
              echo "Unknown option: $1"
              exit 1
              ;;
          esac
        done

        if virsh dominfo "project-$name" &>/dev/null; then
          echo "Stopping VM if running..."
          virsh destroy "project-$name" 2>/dev/null || true
          echo "Removing VM definition..."
          virsh undefine "project-$name"
        fi

        if [[ -d "$project_dir" ]]; then
          if [[ "$keep_data" == "true" ]]; then
            echo "Keeping project data disk, removing other files..."
            rm -f "$project_dir/disk.qcow2"
            rm -f "$project_dir/cloud-init.iso"
            rm -f "$project_dir/domain.xml"
            rm -f "$project_dir/user-data"
            rm -f "$project_dir/meta-data"
            echo "Project data preserved at: $project_dir/project.qcow2"
          else
            echo "Removing all VM files..."
            rm -rf "$project_dir"
          fi
        fi

        echo "VM 'project-$name' destroyed."
      }

      ssh_vm() {
        local name="$1"
        echo "Connecting to project-$name.bat-boa.ts.net..."
        ssh -o StrictHostKeyChecking=accept-new "dev@project-$name.bat-boa.ts.net"
      }

      list_vms() {
        echo "Project VMs:"
        echo ""
        for dir in "$STORAGE_DIR"/*/; do
          if [[ -d "$dir" && "$dir" != "$STORAGE_DIR/base/" ]]; then
            local name
            name=$(basename "$dir")
            local state="undefined"
            if virsh dominfo "project-$name" &>/dev/null; then
              state=$(virsh domstate "project-$name" 2>/dev/null || echo "unknown")
            fi
            printf "  %-20s %s\n" "$name" "$state"
          fi
        done
      }

      status_vm() {
        local name="$1"
        local project_dir="$STORAGE_DIR/$name"

        echo "Project VM: $name"
        echo ""

        if virsh dominfo "project-$name" &>/dev/null; then
          virsh dominfo "project-$name"
        else
          echo "VM is not defined in libvirt"
        fi

        echo ""
        echo "Disk usage:"
        if [[ -f "$project_dir/disk.qcow2" ]]; then
          qemu-img info "$project_dir/disk.qcow2" | grep -E '(virtual size|disk size)'
        fi
        if [[ -f "$project_dir/project.qcow2" ]]; then
          echo ""
          echo "Project disk:"
          qemu-img info "$project_dir/project.qcow2" | grep -E '(virtual size|disk size)'
        fi
      }

      console_vm() {
        local name="$1"
        if ! virsh dominfo "project-$name" &>/dev/null; then
          echo "Error: VM 'project-$name' does not exist"
          exit 1
        fi
        echo "Attaching to console (Ctrl+] to exit)..."
        virsh console "project-$name"
      }

      # Main command dispatch
      case "''${1:-}" in
        create)
          [[ -z "''${2:-}" ]] && usage
          create_vm "''${2}" "''${3:-}" "''${4:-}" "''${5:-}"
          ;;
        start)
          [[ -z "''${2:-}" ]] && usage
          start_vm "''${2}"
          ;;
        stop)
          [[ -z "''${2:-}" ]] && usage
          stop_vm "''${2}"
          ;;
        destroy)
          [[ -z "''${2:-}" ]] && usage
          destroy_vm "''${2}" "''${@:3}"
          ;;
        ssh)
          [[ -z "''${2:-}" ]] && usage
          ssh_vm "''${2}"
          ;;
        list)
          list_vms
          ;;
        status)
          [[ -z "''${2:-}" ]] && usage
          status_vm "''${2}"
          ;;
        console)
          [[ -z "''${2:-}" ]] && usage
          console_vm "''${2}"
          ;;
        *)
          usage
          ;;
      esac
    '';
  };
in {
  options.constellation.projectVms = {
    enable = mkEnableOption "project isolation VMs with Debian testing";

    storageDir = mkOption {
      type = types.path;
      default = "/var/lib/project-vms";
      description = "Directory for storing VM images and data.";
    };

    defaultMemory = mkOption {
      type = types.int;
      default = 8192;
      description = "Default memory in MB for new VMs.";
    };

    defaultCpus = mkOption {
      type = types.int;
      default = 4;
      description = "Default number of CPUs for new VMs.";
    };

    defaultDiskSize = mkOption {
      type = types.str;
      default = "50G";
      description = "Default project disk size for new VMs.";
    };

    tailscaleAuthKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the Tailscale auth key.
        This key should be reusable and pre-authorized with appropriate tags.
        Generate one at: https://login.tailscale.com/admin/settings/keys
      '';
      example = literalExpression "config.sops.secrets.tailscale-project-vm-key.path";
    };

    sshPublicKey = mkOption {
      type = types.str;
      description = "SSH public key to authorize for the 'dev' user in VMs.";
      example = "ssh-ed25519 AAAA... user@host";
    };

    projects = mkOption {
      type = types.attrsOf (types.submodule projectOpts);
      default = {};
      description = "Declaratively defined project VMs (optional, CLI can also create VMs).";
      example = literalExpression ''
        {
          myapp = {
            memory = 16384;
            cpus = 8;
            diskSize = "100G";
          };
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    # Ensure virtualization is enabled
    constellation.virtualization.enable = true;

    # Install the CLI tool
    environment.systemPackages = [projectVmCli];

    # Create directory structure
    systemd.tmpfiles.rules = [
      "d ${cfg.storageDir} 0755 root root -"
      "d ${cfg.storageDir}/base 0755 root root -"
    ];

    # Systemd service to download Debian cloud image
    systemd.services.project-vm-base = {
      description = "Download Debian testing cloud image for project VMs";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "download-debian-image" ''
          set -euo pipefail
          IMAGE_PATH="${cfg.storageDir}/base/${debianImageName}"
          IMAGE_URL="${debianImageUrl}"

          # Check if image already exists and is valid
          if [[ -f "$IMAGE_PATH" ]]; then
            echo "Image already exists at $IMAGE_PATH"
            # Verify it's a valid qcow2
            if ${pkgs.qemu}/bin/qemu-img info "$IMAGE_PATH" &>/dev/null; then
              echo "Image is valid, skipping download."
              exit 0
            else
              echo "Image appears corrupted, re-downloading..."
              rm -f "$IMAGE_PATH"
            fi
          fi

          echo "Downloading Debian testing cloud image..."
          ${pkgs.curl}/bin/curl -L -o "$IMAGE_PATH.tmp" "$IMAGE_URL"
          mv "$IMAGE_PATH.tmp" "$IMAGE_PATH"
          echo "Download complete: $IMAGE_PATH"
        '';
      };
    };

    # Ensure libvirt default network is available
    systemd.services.libvirtd-config = {
      description = "Configure libvirt default network";
      after = ["libvirtd.service"];
      requires = ["libvirtd.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "configure-libvirt-network" ''
          set -euo pipefail

          # Check if default network exists
          if ! ${pkgs.libvirt}/bin/virsh net-info default &>/dev/null; then
            echo "Creating default network..."
            ${pkgs.libvirt}/bin/virsh net-define /dev/stdin << 'EOF'
          <network>
            <name>default</name>
            <forward mode='nat'/>
            <bridge name='virbr0' stp='on' delay='0'/>
            <ip address='192.168.122.1' netmask='255.255.255.0'>
              <dhcp>
                <range start='192.168.122.2' end='192.168.122.254'/>
              </dhcp>
            </ip>
          </network>
          EOF
          fi

          # Ensure network is active
          if ! ${pkgs.libvirt}/bin/virsh net-info default | grep -q "Active:.*yes"; then
            echo "Starting default network..."
            ${pkgs.libvirt}/bin/virsh net-start default || true
          fi

          # Ensure network auto-starts
          ${pkgs.libvirt}/bin/virsh net-autostart default || true
        '';
      };
    };
  };
}
