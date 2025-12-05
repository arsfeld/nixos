# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  config,
  pkgs,
  ...
}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  boot = {
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "amdgpu"];
  };

  networking.hostName = "striker";

  # Enable networking
  networking.networkmanager.enable = true;
  # networking.useNetworkd = true;

  boot.plymouth.enable = true;
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;
  boot.kernelParams = ["quiet" "udev.log_level=3"];

  users.users.forgejo_runner = {
    description = "Forgejo Actions Runner Service";
    home = "/var/lib/forgejo_runner";
    useDefaultShell = true;
    group = "forgejo_runner";
    isSystemUser = true;
    extraGroups = ["docker"];
  };

  users.groups.forgejo_runner = {};

  systemd.services.forgejo_runner = {
    enable = true;
    description = "Forgejo actions runner";
    serviceConfig = {
      ExecStart = "${pkgs.forgejo-actions-runner}/bin/forgejo-runner daemon";
    };
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = "forgejo_runner";
      Group = "forgejo_runner";
      WorkingDirectory = "/var/lib/forgejo_runner";
    };
  };

  # Enable the Pantheon Desktop Environment.
  # services.xserver.displayManager.lightdm.enable = true;
  # services.xserver.desktopManager.pantheon.enable = true;

  # services.pantheon.apps.enable = true;
  # services.pantheon.contractor.enable = true;
  # programs.pantheon-tweaks.enable = true;

  # services.xserver.desktopManager.pantheon.extraWingpanelIndicators = [
  #   pkgs.wingpanel-indicator-ayatana
  # ];

  services.flatpak.enable = true;

  #programs.steam.enable = true;
  hardware.steam-hardware.enable = true;

  # Vulkan
  hardware.graphics.enable32Bit = true;

  #services.xserver.videoDrivers = ["amd"];
  services.xserver.videoDrivers = ["amdgpu"];
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      vaapiVdpau
      libvdpau-va-gl
      rocm-opencl-icd
      rocm-opencl-runtime
      amdvlk
    ];
  };

  hardware.graphics.extraPackages32 = with pkgs; [
    driversi686Linux.amdvlk
  ];

  services.avahi.enable = true;
  services.avahi.nssmdns4 = true;

  time.timeZone = "America/Toronto";
  i18n.defaultLocale = "en_CA.utf8";

  services.xserver.enable = true;

  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  services.xserver.displayManager.gdm.autoSuspend = false;

  services.gnome.gnome-keyring.enable = true;
  programs.seahorse.enable = true;

  programs.gamemode.enable = true;

  # Enable sound with pipewire.
  sound.enable = true;
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.arosenfeld = {
    packages = with pkgs; [
      firefox
      celluloid
      torrential
      gnome-console
      gnome.adwaita-icon-theme
    ];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
    vscode
    gnomeExtensions.appindicator
    gnomeExtensions.random-wallpaper
    gnomeExtensions.zfs-status-monitor
    gnomeExtensions.wireless-hid
    gnomeExtensions.tailscale-status
    gnomeExtensions.dash2dock-lite
  ];

  services.udev.packages = with pkgs; [gnome.gnome-settings-daemon];

  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.05"; # Did you read the comment?
}
