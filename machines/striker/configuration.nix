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
    kernelModules = ["kvm-intel"];
  };

  networking.hostName = "striker";

  # Enable networking
  # networking.networkmanager.enable = true;
  networking.useNetworkd = true;

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.utf8";

  # Enable the X11 windowing system.
  #services.xserver.enable = true;

  boot.plymouth.enable = true;
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;
  boot.kernelParams = ["quiet" "udev.log_level=3"];

  users.users.gitea_act = {
    description = "Gitea Act Runner Service";
    home = "/var/lib/gitea_act";
    useDefaultShell = true;
    group = "gitea_act";
    isSystemUser = true;
    extraGroups = ["docker"];
  };

  users.groups.gitea_act = {};

  systemd.services.gitea_act = {
    enable = true;
    description = "Gitea act runner";
    serviceConfig = {
      ExecStart = "${pkgs.gitea-actions-runner}/bin/act_runner daemon";
    };
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = "gitea_act";
      Group = "gitea_act";
      WorkingDirectory = "/var/lib/gitea_act";
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

  # services.flatpak.enable = true;

  # # Configure keymap in X11
  # services.xserver = {
  #   layout = "us";
  #   xkbVariant = "alt-intl";
  # };

  # # Configure console keymap
  # console.keyMap = "dvorak";

  # # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound with pipewire.
  # sound.enable = true;
  # hardware.pulseaudio.enable = false;
  # security.rtkit.enable = true;
  # services.pipewire = {
  #   enable = true;
  #   alsa.enable = true;
  #   alsa.support32Bit = true;
  #   pulse.enable = true;
  # };

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
  ];

  # fonts.fonts = with pkgs; [
  #   (nerdfonts.override {fonts = ["FiraCode" "CascadiaCode"];})
  # ];

  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.05"; # Did you read the comment?
}
