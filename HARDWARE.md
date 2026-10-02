# Hardware Inventory

Last updated: 2026-04-07

## Online Hosts

### galactica
- **Role**: Main server (media, databases, backups)
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

### basestar
- **Role**: Public-facing server (BSG Cylon Basestar)
- **Architecture**: aarch64
- **CPU**: ARM Neoverse-N1 - 4 cores / 4 threads
- **RAM**: 24 GB
- **Disks**:
  - `sda` 100 GB - Block Volume (cloud provider)
- **Note**: Oracle Cloud VM instance

### cylon-link
- **Role**: Always-on helper (Valve Steam Link running NixOS)
- **Architecture**: armv7l (cross-compiled from x86_64)
- **CPU**: Marvell Berlin BG2CD (DE3005), ARM Cortex-A9 - 1 core visible
- **RAM**: 512 MB (463 MiB usable under the mainline kernel)
- **Disks**:
  - USB 28.8 GB - Kingston DataTraveler 3.0 (`CYLON_BOOT` 1 GiB ext3 + `CYLON_ROOT` ext4)
  - internal 1 GB NAND - unused (no mainline driver)
- **Network**: 100 Mb Ethernet (`pxa168_eth`, MAC e0:31:9e:19:06:5c); Marvell SDIO Wi-Fi/BT unused
- **Note**: No reboot, no video output under the mainline kernel

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

### pegasus
- **Role**: Secondary server (media, off-site)
- **Architecture**: x86_64
- **Board**: Gigabyte H97N-WIFI (mini-ITX, one PCIe x16 slot)
- **CPU**: Intel Core i5-4430 - 4 cores / 4 threads
- **RAM**: 16 GB
- **Network**: 2x onboard gigabit Ethernet (Intel I217-V, Atheros AR8161)
- **Expansion card**: Fujitsu D2607 SAS HBA (LSI SAS2008, `mpt2sas`), in the only PCIe slot. Crossflashed: firmware reports `SAS9212-4i4e`, version 20.00.07.00. Two internal SFF-8087 connectors, 8 lanes; phys 4-7 are in use, phys 0-3 are free.
- **Disks** (identify by serial; `/dev/sdX` names change on this host):

  | Size | Model | Serial | Use | Connected to |
  |------|-------|--------|-----|--------------|
  | 512 GB SSD | Samsung MZ7LN512HMJP | S2URNX0HC00771 | boot, containers | onboard SATA port 1 |
  | 4 TB | Seagate ST4000VN000 | Z3051HFQ | pool devid 1 | onboard SATA port 2 |
  | 4 TB | Seagate ST4000VN008 | WDH2WDVD | pool devid 2 | HBA phy 4 |
  | 4 TB | WD WD40EFRX | WD-WCC7K7HJ9TV6 | pool devid 3 | HBA phy 5 |
  | 4 TB | Seagate ST4000VN008 | WDH2Y01G | pool devid 4 | HBA phy 6 |
  | 4 TB | Seagate ST4000VN000 | Z304SS33 | pool devid 5 | HBA phy 7 |

- **Cabling**: the four HBA disks are SATA drives, so they hang off one SFF-8087 to 4x SATA forward breakout cable (inferred from the card and the drives, not seen). Four onboard SATA ports are free.
- **Pool**: `cottage-data`, btrfs RAID1C3 across the five 4 TB disks, mounted at `/mnt/storage` (~18 TiB raw, ~6 TiB usable)
- **Known fault**: the phy 7 lane (serial Z304SS33) has dropped its disk off the bus twice under scrub load (July and August 2026). The disk tests healthy; the cable or connector on that lane is the suspect. Not yet replaced. Since 2026-10-02 the lane is capped at 3.0 Gbit at every boot (`sas-phy7-3g`), after it lost sync three times in one night at 6.0 Gbit. The fix is to move that disk to a free onboard SATA port or replace the breakout cable. Details in `hosts/pegasus/configuration.nix`.

## Offline / Unreachable Hosts

The following hosts were not reachable on 2026-04-07:

| Host | Status | Notes |
|------|--------|-------|
| router | Timeout | Custom network device |
| r2s | Timeout | NanoPi R2S ARM router |
| raspi3 | Timeout | Raspberry Pi 3 |
| blackbird | Timeout | ASUS ROG Zephyrus G14 laptop |
| octopi | Timeout | OctoPrint device |
