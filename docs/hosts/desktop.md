# Desktop Systems

## Overview

The desktop systems are personal workstations used for development, gaming, and daily computing tasks. Each system is tailored for specific use cases while maintaining a consistent base configuration.

## Systems

### Raider - Gaming Desktop

#### Hardware Specifications
- **Model**: MSI GE76 Raider (Laptop used as desktop)
- **CPU**: Intel Core i7-11800H (8 cores @ 4.6GHz)
- **GPU**: NVIDIA RTX 3070 (8GB)
- **RAM**: 32GB DDR4
- **Storage**: 1TB NVMe + 2TB NVMe
- **Display**: 17.3" 144Hz + External monitors

#### Configuration Focus
```nix
{
  # Gaming optimizations
  hardware.nvidia = {
    enable = true;
    modesetting.enable = true;
    powerManagement.enable = false;
  };
  
  # Steam and gaming
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };
  
  # Performance governor
  powerManagement.cpuFreqGovernor = "performance";
}
```

#### Installed Software
- **Gaming**: Steam, Lutris, Heroic
- **Streaming**: OBS Studio
- **Development**: VS Code, Docker
- **Media**: Discord, Spotify

### G14 - Portable Laptop

#### Hardware Specifications
- **Model**: ASUS ROG Zephyrus G14
- **CPU**: AMD Ryzen 9 5900HS (8 cores)
- **GPU**: NVIDIA RTX 3060 (6GB)
- **RAM**: 16GB DDR4
- **Storage**: 1TB NVMe
- **Display**: 14" 120Hz
- **Battery**: 76Wh

#### Configuration Focus
```nix
{
  # Power management
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      
      # GPU power management
      RUNTIME_PM_ON_AC = "on";
      RUNTIME_PM_ON_BAT = "auto";
    };
  };
  
  # ASUS-specific
  services.asusd = {
    enable = true;
    enableUserService = true;
  };
}
```

#### Use Cases
- Mobile development
- Travel computing
- Light gaming
- Battery life optimization

### Striker - Development Desktop

#### Hardware Specifications
- **CPU**: AMD Ryzen 7 5800X (8 cores)
- **GPU**: AMD RX 6700 XT
- **RAM**: 32GB DDR4
- **Storage**: 512GB NVMe + 2TB SSD
- **Monitors**: Dual 27" 1440p

#### Configuration Focus
```nix
{
  # Development tools
  virtualisation = {
    docker.enable = true;
    libvirtd.enable = true;
    podman.enable = true;
  };
  
  # AMD GPU
  hardware.opengl = {
    enable = true;
    driSupport = true;
    extraPackages = [ pkgs.amdvlk ];
  };
}
```

#### Development Environment
- **IDEs**: VS Code, IntelliJ IDEA
- **Containers**: Docker, Podman
- **VMs**: libvirt/QEMU
- **Languages**: Nix, Rust, Go, Python

## Common Configuration

### Base Desktop Module

All desktop systems share common configuration:

```nix
# modules/desktop.nix
{
  # Display manager
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  
  # Audio
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = true;
  };
  
  # Printing
  services.printing.enable = true;
  
  # Common software
  environment.systemPackages = with pkgs; [
    firefox
    chromium
    thunderbird
    vscode
    spotify
    discord
    vlc
  ];
}
```

### User Environment

Home Manager configuration for consistent user experience:

```nix
{
  # Shell
  programs.zsh = {
    enable = true;
    oh-my-zsh.enable = true;
  };
  
  # Terminal
  programs.alacritty = {
    enable = true;
    settings = {
      window.opacity = 0.95;
      font.size = 12;
    };
  };
  
  # Git
  programs.git = {
    enable = true;
    userName = "Your Name";
    userEmail = "email@example.com";
  };
}
```

## Display Configuration

### Multi-Monitor Setup

```nix
# Raider with external displays
services.xserver.xrandrHeads = [
  {
    output = "DP-1";
    primary = true;
    mode = "2560x1440";
    rate = "144";
  }
  {
    output = "HDMI-1";
    mode = "1920x1080";
    position = "2560x0";
  }
];
```

### Wayland Support

```nix
# Enable Wayland for supported desktops
services.xserver.displayManager.gdm.wayland = true;

# Firefox Wayland
environment.sessionVariables = {
  MOZ_ENABLE_WAYLAND = "1";
};
```

## Performance Optimization

### Gaming Performance

```nix
# Kernel parameters
boot.kernelParams = [
  "mitigations=off"  # Disable CPU mitigations
  "nowatchdog"       # Disable watchdog
];

# GameMode
programs.gamemode = {
  enable = true;
  settings = {
    general = {
      renice = 10;
      inhibit_screensaver = 1;
    };
  };
};
```

### Development Performance

```nix
# Increase file watchers
boot.kernel.sysctl = {
  "fs.inotify.max_user_watches" = 524288;
  "fs.inotify.max_user_instances" = 1024;
};

# Tmpfs for builds
fileSystems."/tmp" = {
  device = "tmpfs";
  fsType = "tmpfs";
  options = [ "size=16G" "mode=1777" ];
};
```

## Backup Strategy

### What's Backed Up
- User home directories
- Development projects
- Game saves
- Configuration files

### Excluded
- Steam library
- Downloads folder
- Cache directories
- Build artifacts

## Security

### Desktop-Specific Security

```nix
# Firewall for gaming
networking.firewall = {
  enable = true;
  
  # Steam
  allowedTCPPorts = [ 27015 27036 ];
  allowedUDPPorts = [ 27015 27031 ];
  
  # Development
  allowedTCPPortRanges = [
    { from = 3000; to = 3999; }  # Dev servers
    { from = 8000; to = 8999; }  # Local services
  ];
};

# Firejail for browsers
programs.firejail = {
  enable = true;
  wrappedBinaries = {
    firefox = {
      executable = "${pkgs.firefox}/bin/firefox";
      profile = "${pkgs.firejail}/etc/firejail/firefox.profile";
    };
  };
};
```

## Troubleshooting

### GPU Issues

#### NVIDIA
```bash
# Check driver
nvidia-smi

# Restart display manager
systemctl restart display-manager

# Force Vulkan
export VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json
```

#### AMD
```bash
# Check GPU
glxinfo | grep renderer

# Monitor GPU usage
radeontop

# Reset GPU
echo 1 > /sys/bus/pci/devices/0000:XX:00.0/reset
```

### Audio Problems
```bash
# Restart PipeWire
systemctl --user restart pipewire

# Check audio devices
pactl list sinks

# Set default output
pactl set-default-sink <sink-name>
```

## Maintenance

### Regular Updates
```bash
# Update system
sudo nixos-rebuild switch --upgrade

# Update user packages
home-manager switch

# Clean old generations
sudo nix-collect-garbage -d
```

### Performance Monitoring
- CPU/GPU temperatures
- Memory usage
- Disk space
- Network bandwidth

## Future Plans

### Hardware Upgrades
- **Raider**: External GPU dock
- **G14**: RAM upgrade to 32GB
- **Striker**: Optimize 2.5Gb networking

### Software Improvements
- Implement Hyprland for Wayland
- Set up GPU passthrough for VMs
- Configure distributed builds
- Add RGB control for peripherals