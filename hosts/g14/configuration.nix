{
  self,
  config,
  pkgs,
  lib,
  ...
}: {
  imports = self.nixosSuites.base ++ [./hardware-configuration.nix];
  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_zen;

  networking.hostName = "G14";

  boot.kernelParams = [
    "zswap.enabled=1"
    "mitigations=off"
    "splash"
    "quiet"
    "udev.log_level=0"
  ];

  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";

  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

  services.tailscale.enable = true;

  systemd.services.NetworkManager-wait-online.enable = false;

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.UTF-8";

  services.xserver = {
    enable = true;
    #displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };

  services.desktopManager.cosmic.enable = true;
  services.displayManager.cosmic-greeter.enable = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      vaapiVdpau
      libvdpau-va-gl
      amdvlk
    ];
  };

  programs.steam = {
    enable = true;
  };

  services.supergfxd.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "alt-intl";
  };

  # Configure console keymap
  console.keyMap = "us";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.arosenfeld = {
    isNormalUser = true;
    description = "Alexandre Rosenfeld";
    extraGroups = ["networkmanager" "wheel"];
    packages = with pkgs; [
      distrobox
      firefox
      vscode
      gnome-tweaks
      plex-media-player
      vim
      plex-mpv-shim
      mission-center
      ptyxis
      nvtopPackages.full
      jamesdsp-pulse
      multiviewer-for-f1
      woeusb-ng

      # Video/Audio data composition framework tools like "gst-inspect", "gst-launch" ...
      gst_all_1.gstreamer
      # Common plugins like "filesrc" to combine within e.g. gst-launch
      gst_all_1.gst-plugins-base
      # Specialized plugins separated by quality
      gst_all_1.gst-plugins-good
      gst_all_1.gst-plugins-bad
      gst_all_1.gst-plugins-ugly
      # Plugins to reuse ffmpeg to play almost every video format
      gst_all_1.gst-libav
      # Support the Video Audio (Hardware) Acceleration API
      gst_all_1.gst-vaapi

      gradience
      gnome-extension-manager
      gnome-tweaks
      gnomeExtensions.appindicator
      gnomeExtensions.blur-my-shell
      gnomeExtensions.dash-to-dock
      gnomeExtensions.gsconnect
      gnomeExtensions.gtile
      gnomeExtensions.xwayland-indicator
      gnomeExtensions.vitals
      gnomeExtensions.window-gestures
      gnomeExtensions.user-themes
      gnomeExtensions.tiling-shell

      pantheon.elementary-wallpapers

      yaru-theme
      colloid-icon-theme
      colloid-gtk-theme
    ];
  };

  services.asusd.enable = true;
  services.asusd.enableUserService = true;

  programs._1password.enable = true;
  programs._1password-gui.enable = true;
  programs._1password-gui.polkitPolicyOwners = ["arosenfeld"];

  environment.gnome.excludePackages = with pkgs; [
    gnome-photos
    gnome-tour
    gnome-console
    gnome-terminal
    gnome-system-monitor
    geary
    evince
    totem
    gnome-music
    gnome-shell-extensions
    tali # poker game
    iagno # go game
    hitori # sudoku game
    atomix # puzzle game
  ];

  fonts = {
    fontconfig = {
      antialias = true;
      cache32Bit = true;
      hinting.enable = true;
      hinting.autohint = true;
    };
    packages = with pkgs; [
      (nerdfonts.override {fonts = ["FiraCode" "DroidSansMono" "CascadiaCode"];})

      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-emoji
      liberation_ttf
      source-han-sans-japanese
      source-han-serif-japanese

      cascadia-code
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
  ];

  system.stateVersion = "23.11"; # Did you read the comment?
}
