# Constellation tablet sync module
#
# This module provides automatic transcoding and synchronization of media files
# for offline viewing on tablets and mobile devices. It works by:
#
# 1. Scanning media directories for .sync marker files
# 2. Transcoding marked content to tablet-friendly format (H.264, 720p)
# 3. Outputting to a sync folder watched by Syncthing
#
# Usage:
# - Drop an empty .sync file in any show/movie folder to mark it for sync
# - Remove the .sync file to remove content from the sync folder
#
# Transcoding uses Intel QuickSync (VAAPI) for hardware acceleration when available.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.tabletSync;

  # Python script for tablet sync
  tabletSyncPython = pkgs.writeTextFile {
    name = "tablet-sync.py";
    text = ''
      #!/usr/bin/env python3
      """Tablet sync - transcode media for offline viewing."""

      import fcntl
      import json
      import os
      import shutil
      import subprocess
      import sys
      from datetime import datetime
      from pathlib import Path

      # Configuration (injected by Nix)
      MEDIA_DIRS = ${builtins.toJSON cfg.mediaDirectories}
      SYNC_DIR = Path("${cfg.syncDirectory}")
      QUALITY = ${toString cfg.quality}
      PRESET = "${cfg.preset}"
      FFMPEG = "${pkgs.ffmpeg}/bin/ffmpeg"

      LOG_FILE = SYNC_DIR / ".tablet-sync.log"
      LOCK_FILE = SYNC_DIR / ".tablet-sync.lock"

      VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".m4v", ".webm"}


      def log(message: str) -> None:
          """Log a message to both stdout and log file."""
          timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
          line = f"[{timestamp}] {message}"
          print(line, flush=True)
          with open(LOG_FILE, "a") as f:
              f.write(line + "\n")


      def find_sync_markers() -> dict[Path, str]:
          """Find all directories with .sync marker files."""
          sync_sources = {}
          for media_dir in MEDIA_DIRS:
              media_path = Path(media_dir)
              if not media_path.is_dir():
                  continue
              for sync_file in media_path.rglob(".sync"):
                  if sync_file.is_file():
                      source_dir = sync_file.parent
                      try:
                          rel_path = source_dir.relative_to(media_path)
                      except ValueError:
                          rel_path = source_dir.name
                      sync_sources[source_dir] = str(rel_path)
                      log(f"Found sync marker: {source_dir}")
          return sync_sources


      def find_video_files(source_dir: Path) -> list[Path]:
          """Find all video files in a directory recursively."""
          videos = []
          for ext in VIDEO_EXTENSIONS:
              videos.extend(source_dir.rglob(f"*{ext}"))
          return sorted(videos)


      def needs_transcode(source: Path, dest: Path) -> bool:
          """Check if source needs to be transcoded."""
          if not dest.exists():
              return True
          return source.stat().st_mtime > dest.stat().st_mtime


      def transcode_vaapi(source: Path, dest: Path) -> bool:
          """Try hardware-accelerated transcoding with VAAPI."""
          # Use format=nv12 to handle 10-bit content before hwupload
          cmd = [
              FFMPEG, "-y", "-loglevel", "warning", "-stats",
              "-init_hw_device", "vaapi=va:/dev/dri/renderD128",
              "-i", str(source),
              "-filter_hw_device", "va",
              "-vf", "format=nv12,hwupload,scale_vaapi=w=1280:h=-2",
              "-c:v", "h264_vaapi", "-qp", str(QUALITY),
              "-c:a", "aac", "-b:a", "128k", "-ac", "2",
              "-movflags", "+faststart",
              str(dest),
          ]
          result = subprocess.run(cmd, capture_output=False)
          return result.returncode == 0


      def transcode_software(source: Path, dest: Path) -> bool:
          """Software-based transcoding fallback."""
          cmd = [
              FFMPEG, "-y", "-loglevel", "warning", "-stats",
              "-i", str(source),
              "-vf", "scale=1280:-2",
              "-c:v", "libx264", "-crf", str(QUALITY), "-preset", PRESET,
              "-c:a", "aac", "-b:a", "128k", "-ac", "2",
              "-movflags", "+faststart",
              str(dest),
          ]
          result = subprocess.run(cmd, capture_output=False)
          return result.returncode == 0


      def transcode_file(source: Path, dest: Path) -> bool:
          """Transcode a video file, trying VAAPI first then software."""
          temp_file = dest.with_suffix(".tmp.mp4")
          temp_file.parent.mkdir(parents=True, exist_ok=True)

          log(f"  Transcoding: {source.name} -> {dest.name}")

          # Try VAAPI first
          log("  Using VAAPI hardware encoding...")
          if transcode_vaapi(source, temp_file):
              temp_file.rename(dest)
              log(f"  Completed (VAAPI): {dest.name}")
              return True

          # Fall back to software
          log("  VAAPI failed, trying software encoding...")
          temp_file.unlink(missing_ok=True)

          if transcode_software(source, temp_file):
              temp_file.rename(dest)
              log(f"  Completed (software): {dest.name}")
              return True

          log(f"  FAILED: {source.name}")
          temp_file.unlink(missing_ok=True)
          return False


      def process_sync_source(source_dir: Path, rel_path: str) -> None:
          """Process all video files in a sync source directory."""
          dest_dir = SYNC_DIR / rel_path
          dest_dir.mkdir(parents=True, exist_ok=True)

          log(f"Processing: {rel_path}")

          for video_file in find_video_files(source_dir):
              # Preserve subdirectory structure (e.g., Season 1/)
              try:
                  video_rel = video_file.relative_to(source_dir)
              except ValueError:
                  video_rel = Path(video_file.name)

              dest_file = dest_dir / video_rel.with_suffix(".mp4")

              if not needs_transcode(video_file, dest_file):
                  log(f"  Skipping (up to date): {video_file.name}")
                  continue

              transcode_file(video_file, dest_file)


      def cleanup_old_syncs(expected_dirs: set[str]) -> None:
          """Remove directories that no longer have .sync markers."""
          log("Cleaning up removed sync markers...")
          if not SYNC_DIR.is_dir():
              return

          for item in SYNC_DIR.iterdir():
              if item.is_dir() and item.name not in expected_dirs:
                  # Skip hidden directories like .stfolder
                  if item.name.startswith("."):
                      continue
                  log(f"Removing: {item.name} (sync marker removed)")
                  shutil.rmtree(item)


      def main() -> int:
          """Main entry point."""
          # Ensure sync directory exists
          SYNC_DIR.mkdir(parents=True, exist_ok=True)

          # Acquire lock to prevent concurrent runs
          lock_fd = open(LOCK_FILE, "w")
          try:
              fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
          except BlockingIOError:
              print("Another instance is already running")
              return 0

          try:
              log("Starting tablet sync...")

              sync_sources = find_sync_markers()
              if not sync_sources:
                  log("No .sync markers found")

              expected_dirs = set()
              for source_dir, rel_path in sync_sources.items():
                  # Track top-level directory for cleanup
                  top_dir = rel_path.split("/")[0]
                  expected_dirs.add(top_dir)

                  process_sync_source(source_dir, rel_path)

              cleanup_old_syncs(expected_dirs)

              log("Tablet sync complete")
              return 0

          finally:
              fcntl.flock(lock_fd, fcntl.LOCK_UN)
              lock_fd.close()


      if __name__ == "__main__":
          sys.exit(main())
    '';
  };

  # Wrapper script
  tabletSyncScript = pkgs.writeShellScriptBin "tablet-sync" ''
    exec ${pkgs.python3}/bin/python3 ${tabletSyncPython} "$@"
  '';
in {
  options.constellation.tabletSync = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable tablet sync service for transcoding and syncing media
        to mobile devices via Syncthing.
      '';
    };

    mediaDirectories = mkOption {
      type = types.listOf types.path;
      default = ["/mnt/storage/media/Series" "/mnt/storage/media/Movies"];
      description = ''
        List of media directories to scan for .sync marker files.
      '';
    };

    syncDirectory = mkOption {
      type = types.path;
      default = "/mnt/storage/media/Sync";
      description = ''
        Output directory for transcoded files. This should be watched by Syncthing.
      '';
    };

    quality = mkOption {
      type = types.int;
      default = 23;
      description = ''
        Video quality (CRF for software, QP for hardware encoding).
        Lower = better quality, larger files. 23 is a good balance.
      '';
    };

    preset = mkOption {
      type = types.str;
      default = "medium";
      description = ''
        Encoding preset for software encoding (ultrafast, fast, medium, slow).
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "hourly";
      description = ''
        How often to run the sync (systemd calendar format).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "media";
      description = ''
        User to run the sync service as.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = ''
        Group to run the sync service as.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Make the script available system-wide
    environment.systemPackages = [tabletSyncScript];

    # Create the sync directory
    systemd.tmpfiles.rules = [
      "d ${cfg.syncDirectory} 0775 ${cfg.user} ${cfg.group} -"
    ];

    # Systemd service for tablet sync
    systemd.services.tablet-sync = {
      description = "Transcode media for tablet sync";
      after = ["network.target" "local-fs.target"];
      path = [pkgs.ffmpeg pkgs.python3];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tabletSyncScript}/bin/tablet-sync";
        User = cfg.user;
        Group = cfg.group;
        Nice = 19;
        IOSchedulingClass = "idle";
        # Allow access to GPU for hardware encoding
        SupplementaryGroups = ["video" "render"];
      };
    };

    # Timer to run periodically
    systemd.timers.tablet-sync = {
      description = "Tablet sync timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
