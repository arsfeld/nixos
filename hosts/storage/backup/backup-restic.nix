{
  config,
  self,
  ...
}: {
  age.secrets."restic-password".file = "${self}/secrets/restic-password.age";
  age.secrets."hetzner-storagebox-ssh-key" = {
    file = "${self}/secrets/hetzner-storagebox-ssh-key.age";
    mode = "0400";
    path = "/root/.ssh/hetzner_storagebox";
  };
  age.secrets."hetzner-webdav-env" = {
    file = "${self}/secrets/hetzner-webdav-env.age";
    mode = "0400";
  };

  services.restic.backups = {
    # Local backup: Root disk only (system state, no user data or media)
    nas = {
      paths = ["/"];
      exclude = [
        "/dev"
        "/proc"
        "/sys"
        "/nix"
        "/mnt"
        "/media"
        "/tmp"
        "/var/cache"
        "/home/*/.cache"
        "/home"
        "/run"
        "/var/lib/docker"
        "/var/lib/containers"
        "/var/lib/lxcfs"
      ];
      repository = "/mnt/storage/backups/restic";
      passwordFile = config.age.secrets."restic-password".path;
      initialize = true;
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "5h";
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 12"
      ];
    };

    # Remote backup: NVMe system state (service configs + databases)
    hetzner-system = {
      paths = ["/"];
      exclude = [
        # Already backed up remotely in `hetzner` profile
        "/home"
        "/mnt"

        # Virtual/runtime filesystems
        "/dev"
        "/proc"
        "/sys"
        "/run"
        "/tmp"

        # Nix store (reproducible from flake)
        "/nix"

        # Caches
        "/var/cache"

        # Container layers (regenerable, large)
        "/var/lib/docker"
        "/var/lib/containers"
        "/var/lib/lxcfs"

        # Metrics/logs (regenerable)
        "/var/lib/loki"
        "/var/lib/prometheus2"
      ];

      repository = "rclone:hetzner:backups/restic-system";
      passwordFile = config.age.secrets."restic-password".path;
      environmentFile = config.age.secrets."hetzner-webdav-env".path;
      initialize = true;
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "1h";
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
    };

    # Remote backup: User data and important files only (no system state or /nix)
    hetzner = {
      paths = [
        "/home"
        "/mnt/storage"
      ];
      exclude = [
        # /mnt/storage exclusions
        "/mnt/storage/backups"
        "/mnt/storage/media"
        "/mnt/storage/homes" # same as /home
        "/mnt/storage/legacy"

        # Caches
        "/home/*/.cache"
        "/home/*/.local/share/containers"

        # Dev tooling (many small files, reinstallable)
        "/home/*/.cargo"
        "/home/*/.rustup"
        "/home/*/.npm"
        "/home/*/.npm-global"
        "/home/*/.npm-packages"
        "/home/*/.nvm"
        "/home/*/.bun"
        "/home/*/go"
        "/home/*/.hex"
        "/home/*/.mix"
        "/home/*/.linuxbrew"
        "/home/*/.local/share/pnpm"

        # Remote IDE servers (reinstallable)
        "/home/*/.vscode-server"
        "/home/*/.cursor-server"
        "/home/*/.openvscode-server"
        "/home/*/.zed_server"
        "/home/*/.devpod"

        # AI tool caches (reinstallable)
        "/home/*/.claude"
        "/home/*/.claude-code-router"
        "/home/*/.codex"
        "/home/*/.copilot"
        "/home/*/.gemini"
        "/home/*/.qwen"
        "/home/*/.tailout"

        # Large dirs already stored elsewhere or replaceable
        "/home/*/Takeout"
        "/home/*/Backup"
        "/home/*/torrents"

        # Other regenerable state
        "/home/*/.docker"
        "/home/*/.dropbox-dist"
        "/home/*/.wine"
        "/home/*/.nix-defexpr"
        "/home/*/.nix-profile"
        "/home/*/.terraform.d"
      ];

      # Hetzner Storage Box via WebDAV (rclone backend)
      repository = "rclone:hetzner:backups/restic";
      passwordFile = config.age.secrets."restic-password".path;
      environmentFile = config.age.secrets."hetzner-webdav-env".path;
      initialize = true;
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "1h";
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
    };
  };

  # Set I/O priority for backup jobs to idle class to prevent disk I/O congestion
  systemd.services = {
    restic-backups-nas.serviceConfig = {
      IOSchedulingClass = "idle";
    };
    restic-backups-hetzner.serviceConfig = {
      TimeoutStartSec = "infinity";
    };
    restic-backups-hetzner-system.serviceConfig = {
      TimeoutStartSec = "infinity";
      IOSchedulingClass = "idle";
    };
  };
}
