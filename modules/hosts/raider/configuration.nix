{
  configurations.nixos.raider.module = {
    config,
    pkgs,
    ...
  }: {
    # Enable sops-nix for secrets management

    # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
    # publishes). owner + mode let the user-mode script read it directly.
    sops.secrets."ntfy-publisher-env" = {
      sopsFile = ../../../secrets/sops/ntfy-client.yaml;
      owner = "arosenfeld";
      mode = "0400";
    };

    # Allow insecure packages
    nixpkgs.config.permittedInsecurePackages = [
      "mbedtls-2.28.10"
    ];

    # Enable constellation modules
    constellation = {
      desktop = {
        # Experimental. "gnome" is the way back: the GNOME settings below and in
        # appearance.nix are inert under Pantheon and kept for that switch.
        variant = "pantheon";
        pantheon.dockStacks = [
          {
            source = "~/Downloads";
            view = "fan";
            sort = "date-added";
          }
          {
            source = "applications";
            display = "grid";
          }
        ];
      };
      gaming = {
        cpuVendor = "intel";
        # sched_ext (scx_lavd 1.1.3) has ABI mismatch on Linux 7.1+ (missing
        # rescue_bandwidth_ppt / rescue_quantum_us) and starves UI threads under
        # high CPU load on Intel hybrid topology, triggering runnable task stall
        # kernel aborts. Stick with kernel default EEVDF.
        scheduler = "none";
        # i5-12500H: CPUs 0-7 are the four SMT P-cores (4500 MHz), 8-15 the eight
        # E-cores (3300 MHz). Confine nix-daemon and agents.slice to the E-cores
        # while a game runs so builds never contend for a P-core with the game.
        backgroundCpus = "8-15";
        # Claude Code agents (home/home.nix) yield the P-cores the same way.
        backgroundUserSlices = ["agents.slice"];
        # 3440x1440@144 ultrawide — pin gamescope's output mode to the panel.
        gamescope = {
          width = 3440;
          height = 1440;
          refreshRate = 144;
        };
      };
    };

    # Project Isolation VMs (Tailscale disabled for now — uses libvirt network SSH)
    constellation.projectVms = {
      sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
    };

    # Mark raider as a development machine for netdata alert filtering
    services.netdata.config."host labels".environment = "development";

    # Enable media config for domain settings (required by constellation.services)
    media.config.enable = true;

    # Configure Docker storage driver
    virtualisation.docker.storageDriver = "overlay2";

    # Additional packages

    # Android debugging. programs.adb was removed from nixpkgs: systemd >= 258
    # applies the uaccess udev rules itself, so the device nodes are already
    # reachable by the logged-in user and neither android-udev-rules nor an
    # adbusers group membership is needed. Shipping the binaries is the whole
    # of it now.
    environment.systemPackages = with pkgs; [
      android-tools
      anycubic-slicer
      claude-desktop
      firefox
    ];

    # Basic system configuration
    networking.hostName = "raider";

    # Bootloader
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.configurationLimit = 5;
    boot.loader.efi.canTouchEfiVariables = true;

    # nfs for the media mount; the rest come from constellation.desktop.
    boot.supportedFilesystems = ["nfs"];

    # Disable aggressive SATA power management to prevent SSD freezing
    boot.kernelParams = ["ahci.mobile_lpm_policy=0"];
    powerManagement.scsiLinkPolicy = "max_performance";

    # Filebrowser - web-based file manager accessible from browser/iPhone
    services.filebrowser = {
      enable = true;
      user = "arosenfeld";
      group = "users";
      settings = {
        address = "0.0.0.0";
        port = 8080;
        root = "/home/arosenfeld";
      };
    };

    # Disable firewall for development
    networking.firewall.enable = false;

    # Environment variables for games
    environment.sessionVariables.GAMES_DIR = "/mnt/games";

    # This value determines the NixOS release from which the default
    # settings for stateful data, like file locations and database versions
    # on your system were taken. It's perfectly fine and recommended to leave
    # this value at the release version of the first install of this system.
    system.stateVersion = "23.05";
  };
}
