# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.config.allowUnfree = true;
  nix.settings.trusted-users = ["root" "arosenfeld"];

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "G14";
  networking.networkmanager.enable = true; 

  virtualisation.podman.enable = true;
  virtualisation.podman.dockerSocket.enable = true;
  virtualisation.podman.dockerCompat = true;

  programs.steam.enable = true;
  hardware.steam-hardware.enable = true;

  services.xserver.videoDrivers = ["nvidia"];
  services.switcherooControl.enable = true;
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [
      vaapiVdpau
      libvdpau-va-gl
      rocm-opencl-icd
      rocm-opencl-runtime
      amdvlk
    ];
  };

  hardware.nvidia.prime = {
    offload.enable = true;
    nvidiaBusId = "PCI:1:0:0";
    amdgpuBusId = "PCI:4:0:0";
  };
  hardware.nvidia.powerManagement.enable = true;
  hardware.nvidia.powerManagement.finegrained = true;
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;

  hardware.sane.enable = true;
  hardware.sane.extraBackends = [ pkgs.sane-airscan ];

  services.printing.enable = true;
  services.printing.drivers = [pkgs.samsung-unified-linux-driver];

  services.avahi.enable = true;
  services.avahi.nssmdns = true;

  time.timeZone = "America/Toronto";
  i18n.defaultLocale = "en_CA.utf8";

  services.xserver.enable = true;

  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  services.gnome.gnome-keyring.enable = true;
  programs.seahorse.enable = true;

  # services.xserver.displayManager.lightdm.enable = true;
  # services.xserver.desktopManager.pantheon.enable = true;
  # services.pantheon.apps.enable = true;
  # programs.pantheon-tweaks.enable = true;

  # services.xserver.desktopManager.pantheon.extraWingpanelIndicators = [
  #   pkgs.wingpanel-indicator-ayatana
  # ];

  boot.plymouth.enable = true;

  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  users.users.arosenfeld = {
    isNormalUser = true;
    extraGroups = ["users" "wheel" "podman" "docker" "networkmanager" "scanner" "lp"]; # Enable ‘sudo’ for the user.
    shell = pkgs.zsh;
    packages = with pkgs; [
      firefox-wayland
      gnome.gnome-software
      gnome.gnome-tweaks
      gnomeExtensions.appindicator
      gnomeExtensions.blur-my-shell
      distrobox
      vim
      vscode-fhs
      microsoft-edge
      hypnotix
      protonup-ng

      pantheon.elementary-gtk-theme
      pantheon.elementary-wallpapers
      pantheon.elementary-icon-theme
      moka-icon-theme
      kora-icon-theme
    ];
  };

  programs.zsh.enable = true;

  fonts.fonts = with pkgs; [
    (nerdfonts.override {fonts = ["CascadiaCode" "FiraCode" "DroidSansMono"];})
  ];

  services.flatpak.enable = true;

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.tailscale.enable = true;
  networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.05"; # Did you read the comment?
}
