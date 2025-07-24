# ZFS disko configuration for cottage
# Boot SSD + ZFS RAID array for storage
{ ... }: {
  disko.devices = {
    disk = {
      # Boot SSD - Samsung 512GB
      boot = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HMJP-000L1_S2URNX0HC00771";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "500M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
      
      # Data disks for ZFS RAID
      # Using 3 of the 4TB drives for RAID-Z (equivalent to RAID-5)
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
      data3 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2Y01G";
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
        mode = "raidz";  # RAID-Z equivalent to RAID-5
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
              "com.sun:auto-snapshot" = "true";
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
        
        # Mount options for resilience
        mountOptions = [ "nofail" ];
      };
    };
  };
}