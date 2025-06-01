# Embedded Devices

## Overview

The embedded devices serve specialized purposes in the infrastructure, from low-power computing to IoT applications. These systems are optimized for minimal resource usage and specific tasks.

## Devices

### R2S - Backup Router

#### Hardware Specifications
- **Model**: NanoPi R2S
- **SoC**: Rockchip RK3328 (4x Cortex-A53 @ 1.5GHz)
- **RAM**: 1GB DDR4
- **Storage**: 16GB microSD
- **Network**: 
  - 1x Gigabit WAN (USB 3.0)
  - 1x Gigabit LAN
- **Power**: 5V/2A (~5W)

#### Purpose
Backup router for failover scenarios:
- Secondary DNS server
- Emergency VPN access
- Basic firewall protection
- Network monitoring

#### Special Configuration
```nix
{
  # Custom kernel
  boot.kernelPackages = pkgs.linuxPackages_rockchip;
  
  # Minimal services
  services.openssh.enable = true;
  services.dnsmasq.enable = true;
  
  # Memory optimization
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;
  };
}
```

#### Build Process
Custom SD card image creation:
```bash
# Build R2S image
just r2s

# Flash to SD card
sudo dd if=result/sd-image.img of=/dev/sdX bs=4M status=progress
```

### Raspi3 - IoT Hub

#### Hardware Specifications
- **Model**: Raspberry Pi 3 Model B+
- **SoC**: Broadcom BCM2837B0 (4x Cortex-A53 @ 1.4GHz)
- **RAM**: 1GB LPDDR2
- **Storage**: 32GB microSD
- **Network**: 
  - 1x Gigabit Ethernet (USB 2.0 limited)
  - 802.11ac WiFi
  - Bluetooth 4.2
- **GPIO**: 40-pin header

#### Purpose
Home automation and IoT gateway:
- Zigbee coordinator
- Bluetooth beacon
- Sensor data collection
- Automation scripts

#### Configuration
```nix
{
  # Raspberry Pi specific
  hardware.raspberry-pi."3".enable = true;
  
  # GPIO access
  hardware.deviceTree = {
    enable = true;
    overlays = [ "${pkgs.device-tree_rpi}/overlays/w1-gpio.dtbo" ];
  };
  
  # IoT services
  services.mosquitto = {
    enable = true;
    listeners = [{
      port = 1883;
      users.iot = {
        acl = [ "readwrite #" ];
        hashedPassword = "$6$...";
      };
    }];
  };
  
  # Zigbee2MQTT
  services.zigbee2mqtt = {
    enable = true;
    settings = {
      serial.port = "/dev/ttyUSB0";
      mqtt.server = "mqtt://localhost";
    };
  };
}
```

### Core - Test System

#### Hardware Specifications
- **Model**: Intel NUC (varies)
- **CPU**: Intel Core i3/i5
- **RAM**: 8-16GB
- **Storage**: 256GB SSD
- **Network**: Gigabit Ethernet + WiFi

#### Purpose
Development and testing:
- New service testing
- Configuration experiments
- Backup compute node
- CI/CD runner

#### Flexible Configuration
```nix
{
  # Enable nested virtualization
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  
  # Development tools
  virtualisation = {
    docker.enable = true;
    libvirtd.enable = true;
  };
  
  # Act runner for GitHub Actions
  services.github-runner = {
    enable = true;
    url = "https://github.com/arsfeld/nixos";
    tokenFile = config.age.secrets.github-runner.path;
  };
}
```

### HPE - Server Hardware

#### Hardware Specifications
- **Model**: HPE MicroServer Gen10
- **CPU**: AMD Opteron X3421 (4 cores)
- **RAM**: 16GB ECC
- **Storage**: 4x 3.5" bays
- **Network**: 2x Gigabit Ethernet
- **Remote**: iLO management

#### Purpose
Dedicated server tasks:
- Backup storage
- Build server
- Database host
- Container registry

#### Enterprise Features
```nix
{
  # Hardware monitoring
  services.freeipmi.enable = true;
  
  # Storage configuration
  boot.initrd.kernelModules = [ "bcachefs" ];
  
  # ECC memory monitoring
  hardware.rasdaemon.enable = true;
  
  # Remote management
  networking.firewall.allowedTCPPorts = [ 
    443  # iLO web interface
    17988 # iLO virtual media
  ];
}
```

### Micro - Compact PC

#### Hardware Specifications
- **Form Factor**: Mini PC (7"x7")
- **CPU**: Intel Celeron/Pentium
- **RAM**: 4-8GB
- **Storage**: 128GB SSD
- **Network**: Gigabit Ethernet
- **Power**: <15W

#### Purpose
Edge computing:
- Remote site monitoring
- Local caching proxy
- Backup DNS
- VPN endpoint

#### Minimal Configuration
```nix
{
  # Minimal installation
  environment.systemPackages = with pkgs; [
    vim
    htop
    tmux
  ];
  
  # Disable unnecessary services
  services.xserver.enable = false;
  sound.enable = false;
  
  # Aggressive power saving
  powerManagement = {
    enable = true;
    cpuFreqGovernor = "ondemand";
  };
}
```

## Common Embedded Configuration

### Resource Optimization

```nix
{
  # Reduce memory usage
  boot.kernelParams = [ "cma=32M" ];
  
  # Disable unnecessary features
  documentation.enable = false;
  programs.command-not-found.enable = false;
  
  # Minimal boot
  boot.loader.timeout = 1;
  
  # Compressed memory
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
}
```

### Storage Optimization

```nix
{
  # Use f2fs for flash storage
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "f2fs";
    options = [ "compress_algorithm=zstd" ];
  };
  
  # Reduce writes
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=64M
  '';
  
  # Mount options
  fileSystems."/".options = [ "noatime" "nodiratime" ];
}
```

## Network Configuration

### Embedded Networking

```nix
{
  # Static IPs for reliability
  networking.interfaces.eth0.ipv4.addresses = [{
    address = "192.168.1.50";
    prefixLength = 24;
  }];
  
  # Minimal firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowPing = true;
  };
  
  # mDNS for discovery
  services.avahi = {
    enable = true;
    nssmdns = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };
}
```

## Power Management

### Low Power Configuration

```nix
{
  # CPU scaling
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 50;
      
      # Disk power
      DISK_SPINDOWN_TIMEOUT_ON_AC = "60 60";
      
      # Network power
      WIFI_PWR_ON_AC = "on";
    };
  };
  
  # Suspend configuration
  systemd.targets.sleep.enable = true;
  powerManagement.powertop.enable = true;
}
```

## Monitoring

### Embedded Monitoring

```nix
{
  # Lightweight monitoring
  services.netdata = {
    enable = true;
    config = {
      global = {
        "memory mode" = "ram";
        "update every" = 5;
      };
    };
  };
  
  # Temperature monitoring
  hardware.sensor = {
    enable = true;
    extraArgs = [ "-u" ];
  };
}
```

## Backup Strategy

### Embedded Backups
- Configuration files only
- Exclude logs and temporary data
- Daily backup to main server
- 7-day retention

## Troubleshooting

### Common Issues

#### Boot Problems
```bash
# Check boot messages
journalctl -b

# Verify boot device
fdisk -l

# Check filesystem
fsck /dev/mmcblk0p2
```

#### Network Issues
```bash
# Check connectivity
ip addr show
ping -c 4 router.lan

# Restart networking
systemctl restart systemd-networkd
```

#### Performance Issues
```bash
# Check resources
free -h
df -h

# Monitor processes
htop

# Check temperature
sensors
```

## Development Workflow

### Cross-Compilation

```nix
{
  # Enable cross-compilation
  nixpkgs.crossSystem = {
    config = "aarch64-unknown-linux-gnu";
  };
  
  # Or use remote builders
  nix.buildMachines = [{
    hostName = "storage.bat-boa.ts.net";
    systems = [ "aarch64-linux" ];
    maxJobs = 4;
  }];
}
```

### Testing

1. Build image/configuration
2. Test in VM if possible
3. Deploy to test device
4. Validate functionality
5. Deploy to production

## Future Improvements

### Planned Upgrades
1. **Raspberry Pi 5**: Better performance
2. **NanoPi R5S**: 2.5Gb networking
3. **RISC-V**: Experimental platform
4. **ESP32**: Ultra-low power nodes

### Software Enhancements
- Implement mesh networking
- Add edge computing capabilities
- Improve power management
- Create management dashboard