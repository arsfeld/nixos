{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ./hardware-configuration.nix
  ];

  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "G14";

  boot.kernelParams = ["quiet"];
  boot.plymouth.enable = true;

  time.timeZone = "America/Toronto";

  services.xserver.enable = true;

  systemd.services.NetworkManager-wait-online.enable = false;

  # Enable the GNOME Desktop Environment.
  #services.xserver.displayManager.gdm.enable = true;
  #services.xserver.desktopManager.gnome.enable = true;

  services.xserver.desktopManager.pantheon.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.displayManager.lightdm.greeters.pantheon.enable = true;

  programs.pantheon-tweaks.enable = true;

  services.flatpak.enable = true;

  services.udev.packages = with pkgs; [gnome.gnome-settings-daemon];

  virtualisation.podman.enable = true;
  virtualisation.podman.dockerSocket.enable = true;
  virtualisation.podman.dockerCompat = true;

  services.joycond.enable = true;

  programs.steam.enable = true;
  hardware.steam-hardware.enable = true;
  #services.xserver.videoDrivers = ["nvidia"];

  #services.switcherooControl.enable = true;

  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
    extraPackages = with pkgs; [
      vaapiVdpau
      libvdpau-va-gl
      rocm-opencl-icd
      rocm-opencl-runtime
      amdvlk
    ];
  };

  # hardware.nvidia = {
  #   # PCI-Express Runtime D3 Power Management is enabled by default on this laptop
  #   # But it can fix screen tearing & suspend/resume screen corruption in sync mode
  #   modesetting.enable = true;
  #   # Enable DRM kernel mode setting
  #   powerManagement.enable = true;

  #   prime = {
  #     offload.enable = true;
  #     amdgpuBusId = "PCI:4:0:0";
  #     nvidiaBusId = "PCI:1:0:0";
  #   };
  # };

  services.supergfxd.enable = true;

  services.power-profiles-daemon.enable = false;

  programs.corectrl.enable = true;

  services.tailscale.enable = true;

  services.tlp = {
    enable = true;
    # extraConfig = ''
    settings = {
      # Detailked info can be found https://linrunner.de/tlp/settings/index.html

      # Disables builtin radio devices on boot:
      #   bluetooth
      #   wifi – Wireless LAN (Wi-Fi)
      #   wwan – Wireless Wide Area Network (3G/UMTS, 4G/LTE, 5G)
      # DEVICES_TO_DISABLE_ON_STARTUP="bluetooth wifi"

      # When a LAN, Wi-Fi or WWAN connection has been established, the stated radio devices are disabled:
      #   bluetooth
      #   wifi – Wireless LAN
      #   wwan – Wireless Wide Area Network (3G/UMTS, 4G/LTE, 5G)
      # DEVICES_TO_DISABLE_ON_LAN_CONNECT="wifi wwan"
      # DEVICES_TO_DISABLE_ON_WIFI_CONNECT="wwan"
      # DEVICES_TO_DISABLE_ON_WWAN_CONNECT="wifi"

      # When a LAN, Wi-Fi, WWAN connection has been disconnected, the stated radio devices are enabled.
      # DEVICES_TO_ENABLE_ON_LAN_DISCONNECT="wifi wwan"
      # DEVICES_TO_ENABLE_ON_WIFI_DISCONNECT=""
      # DEVICES_TO_ENABLE_ON_WWAN_DISCONNECT=""

      # Set battery charge thresholds for main battery (BAT0) and auxiliary/Ultrabay battery (BAT1). Values are given as a percentage of the full capacity. A value of 0 is translated to the hardware defaults 96/100%.
      START_CHARGE_THRESH_BAT0 = 30;
      STOP_CHARGE_THRESH_BAT0 = 80;

      # Control battery feature drivers:
      NATACPI_ENABLE = 1;
      TPACPI_ENABLE = 1;
      TPSMAPI_ENABLE = 1;

      # Defines the disk devices the following parameters are effective for. Multiple devices are separated with blanks.
      DISK_DEVICES = "nvme0n1";

      # Set the “Advanced Power Management Level”. Possible values range between 1 and 255.
      #  1 – max power saving / minimum performance – Important: this setting may lead to increased disk drive wear and tear because of excessive read-write head unloading (recognizable from the clicking noises)
      #  128 – compromise between power saving and wear (TLP standard setting on battery)
      #  192 – prevents excessive head unloading of some HDDs
      #  254 – minimum power saving / max performance (TLP standard setting on AC)
      #  255 – disable APM (not supported by some disk models)
      #  keep – special value to skip this setting for the particular disk (synonym: _)
      DISK_APM_LEVEL_ON_AC = "254";
      DISK_APM_LEVEL_ON_BAT = "128";

      # Set the min/max/turbo frequency for the Intel GPU. Possible values depend on your hardware. See the output of tlp-stat -g for available frequencies.
      # INTEL_GPU_MIN_FREQ_ON_AC=0
      # INTEL_GPU_MIN_FREQ_ON_BAT=0
      # INTEL_GPU_MAX_FREQ_ON_AC=0
      # INTEL_GPU_MAX_FREQ_ON_BAT=0
      # INTEL_GPU_BOOST_FREQ_ON_AC=0
      # INTEL_GPU_BOOST_FREQ_ON_BAT=0

      # Selects the CPU scaling governor for automatic frequency scaling.
      # For Intel Core i 2nd gen. (“Sandy Bridge”) or newer Intel CPUs. Supported governors are:
      #  powersave – recommended (kernel default)
      #  performance
      # CPU_SCALING_GOVERNOR_ON_AC=powersave;
      # CPU_SCALING_GOVERNOR_ON_BAT=powersave;

      # Set Intel CPU energy/performance policy HWP.EPP. Possible values are
      #  performance
      #  balance_performance
      #  default
      #  balance_power
      #  power
      # for tlp-stat Version 1.3 and higher 'tlp-stat -p'
      # CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance;
      # CPU_ENERGY_PERF_POLICY_ON_BAT=power;

      # Set Intel CPU energy/performance policy HWP.EPP. Possible values are
      #   performance
      #   balance_performance
      #   default
      #   balance_power
      #   power
      # Version 1.2.2 and lower For version 1.3 and higher this parameter is replaced by CPU_ENERGY_PERF_POLICY_ON_AC/BAT
      # CPU_HWP_ON_AC=balance_performance;
      # CPU_HWP_ON_BAT=power;

      # Define the min/max P-state for Intel Core i processors. Values are stated as a percentage (0..100%) of the total available processor performance.
      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 100;
      CPU_MIN_PERF_ON_BAT = 0;
      CPU_MAX_PERF_ON_BAT = 30;

      RUNTIME_PM_DRIVER_DENYLIST = "nvidia";

      # Disable CPU “turbo boost” (Intel) or “turbo core” (AMD) feature (0 = disable / 1 = allow).
      CPU_BOOST_ON_AC = 1;
      CPU_BOOST_ON_BAT = 0;

      # Minimize number of used CPU cores/hyper-threads under light load conditions (1 = enabled, 0 = disabled). Depends on kernel and processor model.
      SCHED_POWERSAVE_ON_AC = 0;
      SCHED_POWERSAVE_ON_BAT = 1;

      # Set Intel CPU energy/performance policy EPB. Possible values are (in order of increasing power saving):
      #   performance
      #   balance-performance
      #   default (deprecated: normal)
      #   balance-power
      #   power (deprecated: powersave)
      # Version 1.2.2 and lower For version 1.3 and higher this parameter is replaced by CPU_ENERGY_PERF_POLICY_ON_AC/BAT
      # ENERGY_PERF_POLICY_ON_AC=balance-performance;
      # ENERGY_PERF_POLICY_ON_BAT=power;

      # Timeout (in seconds) for the audio power saving mode (supports Intel HDA, AC97). A value of 0 disables power save.
      SOUND_POWER_SAVE_ON_AC = 0;
      SOUND_POWER_SAVE_ON_BAT = 1;

      # Controls runtime power management for PCIe devices.
      # RUNTIME_PM_ON_AC=on;
      # RUNTIME_PM_ON_BAT=auto;

      # Exclude PCIe devices assigned to listed drivers from runtime power management. Use tlp-stat -e to lookup the drivers (in parentheses at the end of each output line).
      # RUNTIME_PM_DRIVER_BLACKLIST="mei_me nouveau nvidia pcieport radeon"

      # Sets PCIe ASPM power saving mode. Possible values:
      #    default – recommended
      #    performance
      #    powersave
      #    powersupersave
      # PCIE_ASPM_ON_AC=default;
      # PCIE_ASPM_ON_BAT=default;
      #'';
    };
  };

  users.users.arosenfeld = {
    isNormalUser = true;
    extraGroups = ["wheel"]; # Enable ‘sudo’ for the user.
    #shell = pkgs.zsh;
    packages = with pkgs; [
      firefox
      tree
      distrobox
      vim
      #vscode
      microsoft-edge
      hypnotix
      protonup-ng
      mangohud
      steamtinkerlaunch

      plex-media-player
      powertop

      gnome.gnome-disk-utility

      jamesdsp-pulse

      # pantheon.elementary-gtk-theme
      # pantheon.elementary-wallpapers
      # pantheon.elementary-icon-theme
      # moka-icon-theme
      # kora-icon-theme
      # fprintd
    ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];

  programs.zsh.enable = true;

  fonts.fonts = with pkgs; [
    (nerdfonts.override {fonts = ["CascadiaCode" "FiraCode" "DroidSansMono"];})
  ];

  environment.systemPackages = with pkgs; [
    vim
    wget
  ];

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.05"; # Did you read the comment?
}
