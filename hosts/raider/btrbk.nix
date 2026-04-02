# Automatic btrfs snapshots of /home using btrbk
# Provides fast local recovery from accidental file deletions.
# Snapshots browsable at /mnt/btrfs-home/.snapshots/
{pkgs, ...}: {
  # Mount the top-level btrfs volume so btrbk can see the /home subvolume
  fileSystems."/mnt/btrfs-home" = {
    device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_1TB_S3PJNF0J907619X-part1";
    fsType = "btrfs";
    options = ["subvolid=5" "noatime" "compress=zstd"];
  };

  # Pre-create the snapshot directory (btrbk does not create it)
  systemd.tmpfiles.rules = [
    "d /mnt/btrfs-home/.snapshots 0755 root root"
  ];

  services.btrbk.instances."home" = {
    onCalendar = "hourly";
    snapshotOnly = true;
    settings = {
      timestamp_format = "long";
      snapshot_preserve_min = "2d";
      snapshot_preserve = "48h 7d 4w";
      volume."/mnt/btrfs-home" = {
        snapshot_dir = ".snapshots";
        subvolume."home" = {};
      };
    };
  };

  environment.systemPackages = [pkgs.btrbk];
}
