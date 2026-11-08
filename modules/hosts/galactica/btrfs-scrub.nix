{
  # Monthly scrub of both btrfs RAID1 filesystems. Without it, a mirror copy
  # left stale by a device dropping off the bus is only repaired when something
  # happens to read it; a scrub reads every block and rewrites the bad copy
  # from the good one before the other side of the mirror can fail too.
  configurations.nixos.galactica.module = {
    services.btrfs.autoScrub = {
      enable = true;
      fileSystems = ["/" "/mnt/storage"];
      interval = "monthly";
    };
  };
}
