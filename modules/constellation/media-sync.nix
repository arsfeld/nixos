# Constellation media sync module
#
# This module provides automatic synchronization of media files from a remote
# host using rsync over SSH. It works by:
#
# 1. Scanning remote directories for .sync marker files
# 2. Syncing marked directories to the local destination
# 3. Cleaning up local directories when markers are removed
#
# Usage:
# - Drop an empty .sync file in any show/movie folder on the source to mark it for sync
# - Remove the .sync file to remove content from the local destination
#
# This is useful for creating local media backups that can be served by Plex.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.mediaSync;

  # Python script for media sync
  mediaSyncPython = pkgs.writeTextFile {
    name = "media-sync.py";
    text = ''
      #!/usr/bin/env python3
      """Media sync - sync marked media from remote host via rsync."""

      import fcntl
      import os
      import shutil
      import subprocess
      import sys
      from datetime import datetime
      from pathlib import Path

      # Configuration (injected by Nix)
      SOURCE_HOST = "${cfg.sourceHost}"
      SOURCE_DIRS = ${builtins.toJSON cfg.sourceDirectories}
      DEST_DIR = Path("${cfg.destDirectory}")
      SSH = "${pkgs.openssh}/bin/ssh"
      RSYNC = "${pkgs.rsync}/bin/rsync"

      LOG_FILE = DEST_DIR / ".media-sync.log"
      LOCK_FILE = DEST_DIR / ".media-sync.lock"


      def log(message: str) -> None:
          """Log a message to both stdout and log file."""
          timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
          line = f"[{timestamp}] {message}"
          print(line, flush=True)
          try:
              with open(LOG_FILE, "a") as f:
                  f.write(line + "\n")
          except Exception:
              pass  # Don't fail if we can't write to log


      def find_remote_sync_markers() -> dict[str, str]:
          """Find all directories with .sync marker files on the remote host.

          Returns a dict mapping source_dir to relative_path for each marked directory.
          """
          sync_sources = {}

          for source_dir in SOURCE_DIRS:
              log(f"Scanning remote: {source_dir}")
              # Find all .sync files on the remote host
              cmd = [
                  SSH, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                  f"root@{SOURCE_HOST}",
                  f"find {source_dir} -name .sync -type f 2>/dev/null"
              ]

              result = subprocess.run(cmd, capture_output=True, text=True)
              if result.returncode != 0:
                  log(f"  Warning: Failed to scan {source_dir}: {result.stderr.strip()}")
                  continue

              for line in result.stdout.strip().split("\n"):
                  if not line:
                      continue
                  sync_file = Path(line)
                  marked_dir = sync_file.parent

                  # Calculate relative path including the category (Movies/Series)
                  # e.g., /mnt/storage/media/Series/Bluey -> Series/Bluey
                  try:
                      category = Path(source_dir).name  # "Series" or "Movies"
                      item_rel = marked_dir.relative_to(source_dir)
                      rel_path = Path(category) / item_rel
                  except ValueError:
                      rel_path = Path(marked_dir.name)

                  sync_sources[str(marked_dir)] = str(rel_path)
                  log(f"  Found sync marker: {marked_dir}")

          return sync_sources


      def sync_directory(remote_path: str, rel_path: str) -> bool:
          """Sync a single directory from the remote host."""
          dest_path = DEST_DIR / rel_path
          dest_path.mkdir(parents=True, exist_ok=True)

          log(f"Syncing: {remote_path} -> {dest_path}")

          # Use rsync with SSH transport
          # -a: archive mode (preserves permissions, times, etc.)
          # -v: verbose
          # --delete: remove files that don't exist on source
          # --progress: show progress
          cmd = [
              RSYNC, "-av", "--delete", "--progress",
              "-e", f"{SSH} -o BatchMode=yes -o StrictHostKeyChecking=accept-new",
              f"root@{SOURCE_HOST}:{remote_path}/",
              f"{dest_path}/"
          ]

          result = subprocess.run(cmd, capture_output=False)
          if result.returncode != 0:
              log(f"  Failed to sync {remote_path}")
              return False

          log(f"  Completed: {rel_path}")
          return True


      def cleanup_old_syncs(expected_paths: set[str]) -> None:
          """Remove directories that no longer have .sync markers on remote."""
          log("Cleaning up removed sync markers...")

          if not DEST_DIR.is_dir():
              return

          # Check each category directory (Movies, Series)
          for category in DEST_DIR.iterdir():
              if not category.is_dir() or category.name.startswith("."):
                  continue

              # Check items within each category
              for item in category.iterdir():
                  if not item.is_dir():
                      continue
                  rel_path = f"{category.name}/{item.name}"
                  if rel_path not in expected_paths:
                      log(f"Removing: {rel_path} (sync marker removed)")
                      shutil.rmtree(item)

              # Remove empty category directories
              if category.is_dir() and not any(category.iterdir()):
                  log(f"Removing empty category: {category.name}")
                  category.rmdir()


      def main() -> int:
          """Main entry point."""
          # Ensure destination directory exists
          DEST_DIR.mkdir(parents=True, exist_ok=True)

          # Acquire lock to prevent concurrent runs
          lock_fd = open(LOCK_FILE, "w")
          try:
              fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
          except BlockingIOError:
              print("Another instance is already running")
              return 0

          try:
              log("Starting media sync...")

              sync_sources = find_remote_sync_markers()
              if not sync_sources:
                  log("No .sync markers found on remote")

              expected_paths = set()
              for remote_path, rel_path in sync_sources.items():
                  # Track full relative path for cleanup (e.g., "Series/Bluey")
                  expected_paths.add(rel_path)
                  sync_directory(remote_path, rel_path)

              cleanup_old_syncs(expected_paths)

              log("Media sync complete")
              return 0

          finally:
              fcntl.flock(lock_fd, fcntl.LOCK_UN)
              lock_fd.close()


      if __name__ == "__main__":
          sys.exit(main())
    '';
  };

  # Wrapper script
  mediaSyncScript = pkgs.writeShellScriptBin "media-sync" ''
    exec ${pkgs.python3}/bin/python3 ${mediaSyncPython} "$@"
  '';
in {
  options.constellation.mediaSync = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable media sync service for syncing marked media from a remote host
        via rsync over SSH. Uses .sync marker files to identify content to sync.
      '';
    };

    sourceHost = mkOption {
      type = types.str;
      default = "storage.bat-boa.ts.net";
      description = ''
        Remote host to sync from (Tailscale hostname or IP).
      '';
    };

    sourceDirectories = mkOption {
      type = types.listOf types.path;
      default = ["/mnt/storage/media/Series" "/mnt/storage/media/Movies"];
      description = ''
        List of directories on the remote host to scan for .sync marker files.
      '';
    };

    destDirectory = mkOption {
      type = types.path;
      default = "/mnt/storage/media";
      description = ''
        Local destination directory for synced media.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "daily";
      description = ''
        How often to run the sync (systemd calendar format).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = ''
        User to run the sync service as. Needs SSH access to the remote host.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Make the script available system-wide
    environment.systemPackages = [mediaSyncScript];

    # Create the destination directory
    systemd.tmpfiles.rules = [
      "d ${cfg.destDirectory} 0755 ${cfg.user} users -"
    ];

    # Systemd service for media sync
    systemd.services.media-sync = {
      description = "Sync marked media from remote host";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = [pkgs.openssh pkgs.rsync pkgs.python3];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mediaSyncScript}/bin/media-sync";
        User = cfg.user;
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    # Timer to run periodically
    systemd.timers.media-sync = {
      description = "Media sync timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}
