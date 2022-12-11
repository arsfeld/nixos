# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  nixpkgs.config.allowUnfree = true;
  nix.settings.trusted-users = [ "root" "arosenfeld" ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "G14"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  virtualisation.podman.enable = true;
  virtualisation.podman.dockerSocket.enable = true;
  virtualisation.podman.dockerCompat = true;

  programs.steam.enable = true;
  hardware.steam-hardware.enable = true;

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.opengl.enable = true;

  hardware.nvidia.prime = {
    offload.enable = true;
    nvidiaBusId = "PCI:1:0:0";
    amdgpuBusId = "PCI:4:0:0";
  };
  hardware.nvidia.powerManagement.enable = true;
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;

  # Set your time zone.
  time.timeZone = "America/Toronto";
  i18n.defaultLocale = "en_CA.utf8";

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
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

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.arosenfeld = {
    isNormalUser = true;
    extraGroups = [ "users" "wheel" "podman" "docker" "networkmanager" ]; # Enable ‘sudo’ for the user.
    shell = pkgs.zsh;
    packages = with pkgs; [
      firefox
      gnome.gnome-software
      gnome.gnome-tweaks
      gnomeExtensions.appindicator
      gnomeExtensions.blur-my-shell
      distrobox
      vim
      vscode-fhs

      pantheon.elementary-gtk-theme
      pantheon.elementary-wallpapers
      pantheon.elementary-icon-theme
      moka-icon-theme
      kora-icon-theme
    ];
  };

  programs.zsh.enable = true;

  fonts.fonts = with pkgs; [
    (nerdfonts.override { fonts = [ "CascadiaCode" "FiraCode" "DroidSansMono" ]; })
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

