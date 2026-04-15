{
  config,
  lib,
  ...
}: let
  # Shared excludes. The two system profiles (hetzner-system,
  # cottage-system) back up root state only — /home and /mnt live in
  # the user profile. The two user profiles (hetzner, cottage) back
  # up /home + /mnt/storage with a big reinstallable-state exclusion
  # list.
  systemExcludes = [
    # Already backed up in the user profile
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

  userExcludes = [
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

  # All four remote profiles share schedule + retention.
  mkRemoteProfile = {
    paths,
    exclude,
    repository,
    environmentFile ? null,
  }:
    {
      inherit paths exclude repository;
      passwordFile = config.sops.secrets."restic-password".path;
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
    }
    // lib.optionalAttrs (environmentFile != null) {inherit environmentFile;};

  systemPaths = ["/"];
  userPaths = ["/home" "/mnt/storage"];
in {
  sops.secrets."restic-password" = {};
  sops.secrets."hetzner-storagebox-ssh-key" = {
    mode = "0400";
    path = "/root/.ssh/hetzner_storagebox";
  };
  sops.secrets."hetzner-webdav-env" = {
    mode = "0400";
  };

  services.restic.backups = {
    # Local backup: daily, long retention, root system state only.
    # Distinct schedule and retention from the remote profiles, so
    # it stays hand-written rather than using mkRemoteProfile.
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
      passwordFile = config.sops.secrets."restic-password".path;
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

    hetzner-system = mkRemoteProfile {
      paths = systemPaths;
      exclude = systemExcludes;
      repository = "rclone:hetzner:backups/restic-system";
      environmentFile = config.sops.secrets."hetzner-webdav-env".path;
    };

    hetzner = mkRemoteProfile {
      paths = userPaths;
      exclude = userExcludes;
      repository = "rclone:hetzner:backups/restic";
      environmentFile = config.sops.secrets."hetzner-webdav-env".path;
    };

    cottage-system = mkRemoteProfile {
      paths = systemPaths;
      exclude = systemExcludes;
      repository = "rest:http://cottage.bat-boa.ts.net:8000/";
    };

    cottage = mkRemoteProfile {
      paths = userPaths;
      exclude = userExcludes;
      repository = "rest:http://cottage.bat-boa.ts.net:8000/";
    };
  };

  # I/O priority and timeout overrides for backup units.
  # User-data profiles need infinite start timeout for multi-day
  # initial seeds; system profiles additionally run as idle I/O so
  # they don't step on interactive workloads.
  systemd.services = let
    slow = {TimeoutStartSec = "infinity";};
    slowIdle = slow // {IOSchedulingClass = "idle";};
  in {
    restic-backups-nas.serviceConfig.IOSchedulingClass = "idle";
    restic-backups-hetzner.serviceConfig = slow;
    restic-backups-hetzner-system.serviceConfig = slowIdle;
    restic-backups-cottage.serviceConfig = slow;
    restic-backups-cottage-system.serviceConfig = slowIdle;
  };
}
