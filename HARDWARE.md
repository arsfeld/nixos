# Hardware Inventory

Last updated: 2026-04-07

## Online Hosts

### storage
- **Role**: Main server (media, databases, backups, k3s)
- **Architecture**: x86_64
- **CPU**: Intel Core i5-1340P (ES, mobile CPU in mATX desktop board) - 12 cores / 16 threads
- **RAM**: 32 GB
- **Disks**:
  - `nvme0n1` 512 GB - Intel SSDPEKNW512G8 (NVMe, boot)
  - `sda` 512 GB - Samsung MZ7LN512HAJQ (SATA SSD)
  - `sdb` 512 GB - Samsung MZ7LN512HAJQ (SATA SSD)
  - `sdc` 8 TB - WDC WD80EDBZ (HDD)
  - `sdd` 8 TB - WDC WD80EDAZ (HDD)
  - `sde` 14 TB - Seagate ST14000NM0121 (HDD)
  - `sdf` 14 TB - Seagate ST14000NM0121 (HDD)
- **Total raw storage**: ~45 TB

### cloud
- **Role**: Cloud server (public-facing services)
- **Architecture**: aarch64
- **CPU**: ARM Neoverse-N1 - 4 cores / 4 threads
- **RAM**: 24 GB
- **Disks**:
  - `sda` 100 GB - Block Volume (cloud provider)
- **Note**: Oracle Cloud VM instance

### raider
- **Role**: Desktop workstation (GNOME, gaming, development)
- **Architecture**: x86_64
- **CPU**: Intel Core i5-12500H (mobile CPU in mITX desktop board) - 12 cores / 16 threads
- **RAM**: 32 GB
- **Disks**:
  - `nvme1n1` 2 TB - Solidigm SSDPFKNU020TZ (NVMe)
  - `nvme0n1` 512 GB - XrayDisk 512GB SSD (NVMe)
  - `sda` 1 TB - Samsung SSD 850 EVO (SATA SSD)
  - `sdb` 512 GB - Samsung MZ7LN512HAJQ (SATA SSD)
- **Total raw storage**: ~4 TB

## Offline / Unreachable Hosts

The following hosts were not reachable on 2026-04-07:

| Host | Status | Notes |
|------|--------|-------|
| router | Timeout | Custom network device |
| r2s | Timeout | NanoPi R2S ARM router |
| raspi3 | Timeout | Raspberry Pi 3 |
| g14 | Timeout | ASUS ROG Zephyrus G14 laptop |
| pegasus | Timeout | Secondary server (BSG Pegasus) |
| octopi | Timeout | OctoPrint device |
