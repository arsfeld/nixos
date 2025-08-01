# ZFS disko configuration for cottage
# ZFS RAID array for storage only (boot disk managed separately)
{...}: {
  disko.devices = {
    disk = {
      # Data disks for ZFS RAID
      # Using 4x 4TB drives for RAID-Z1 (equivalent to RAID-5, tolerates 1 disk failure)
      # NOTE: Excluding failing drive ata-ST4000VN008-2DR166_WDH2Y01G (104 pending sectors)
      data1 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K7HJ9TV6";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "tank";
              };
            };
          };
        };
      };
      data2 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2WDVD";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "tank";
              };
            };
          };
        };
      };
      # data3 removed - failing drive with 104 pending sectors
      # 3rd disk - Seagate 4TB
      data3 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST4000VN000-1H4168_Z304SS33";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "tank";
              };
            };
          };
        };
      };
      # 4th disk - Seagate 4TB
      data4 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST4000VN000-1H4168_Z3051HFQ";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "tank";
              };
            };
          };
        };
      };
    };

    zpool = {
      tank = {
        type = "zpool";
        mode = "raidz"; # RAID-Z1 equivalent to RAID-5, tolerates 1 disk failure
        rootFsOptions = {
          compression = "zstd";
          atime = "off";
          xattr = "sa";
          acltype = "posix";
        };
        datasets = {
          # Dataset for media files
          media = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/media";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };

          # Dataset for backup storage
          backups = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/backups";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "false";
            };
          };

          # Dataset for general data
          data = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/data";
            options = {
              mountpoint = "legacy";
              "com.sun:auto-snapshot" = "true";
            };
          };
        };
      };
    };
  };
}
