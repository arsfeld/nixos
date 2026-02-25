{
  config,
  self,
  ...
}: {
  age.secrets."restic-rest-auth".file = "${self}/secrets/restic-rest-auth.age";
  age.secrets."hetzner-storagebox-ssh-key" = {
    file = "${self}/secrets/hetzner-storagebox-ssh-key.age";
    mode = "0400";
    path = "/root/.ssh/hetzner_storagebox";
  };

  services.restic.backups = {
    # Local backup: Root disk only (system state, no user data or media)
    nas = {
      paths = ["/"];
      exclude = [
        "/dev"
        "/proc"
        "/sys"
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
      repository = "/mnt/data/backups/restic";
      passwordFile = config.age.secrets."restic-password".path;
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "5h";
      };
    };

    # Remote backup: User data and important files only (no system state or /nix)
    servarica = {
      paths = [
        "/home"
        "/mnt/data"
      ];
      exclude = [
        # /mnt/data exclusions
        "/mnt/data/backups"
        "/mnt/data/media"
        "/mnt/data/homes" # same as /home

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
        "/home/*/Downloads"
        "/home/*/torrents"

        # Other regenerable state
        "/home/*/.docker"
        "/home/*/.dropbox-dist"
        "/home/*/.wine"
        "/home/*/.nix-defexpr"
        "/home/*/.nix-profile"
        "/home/*/.terraform.d"
      ];
      repository = "rest:https://servarica.bat-boa.ts.net/";
      passwordFile = config.age.secrets."restic-password".path;
      extraOptions = ["sftp.command='ssh restic@servarica.bat-boa.ts.net'"];
      environmentFile = config.age.secrets."restic-rest-auth".path;
      initialize = false; # Repository already exists
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

    # Pre-migration backup: User data to Hetzner Storage Box via SFTP
    hetzner = {
      paths = [
        "/mnt/storage/homes"
        "/mnt/storage/files"
      ];
      exclude = [];
      repository = "sftp:u547717@u547717.your-storagebox.de:backups/restic";
      passwordFile = config.age.secrets."restic-password".path;
      extraOptions = [
        "sftp.command='ssh -p 23 -i /root/.ssh/hetzner_storagebox -o StrictHostKeyChecking=accept-new u547717@u547717.your-storagebox.de -s sftp'"
      ];
      initialize = true;
      timerConfig = null; # Manual trigger only - no automatic schedule
    };
  };

  # Set I/O priority for backup jobs to idle class to prevent disk I/O congestion
  systemd.services = {
    restic-backups-nas.serviceConfig = {
      IOSchedulingClass = "idle";
    };
    restic-backups-servarica.serviceConfig = {
      IOSchedulingClass = "idle";
    };
    restic-backups-hetzner.serviceConfig = {
      TimeoutStartSec = "infinity";
    };
  };
}
