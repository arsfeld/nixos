{
  config,
  pkgs,
  ...
}: let
  appimage = pkgs.callPackage (import ./appimage.nix) {};
in {
  imports = [
    ./hardware-configuration.nix
    # ./pantheon.nix
  ];

  boot.kernelParams = [
    "zswap.enabled=1"
    "mitigations=off"
    "panic=1"
    "quiet"
    "rd.systemd.show_status=auto"
    "rd.udev.log_priority=3"
    "splash"
  ];

  boot.plymouth = {
    enable = true;
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "raider";

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.supportedFilesystems = ["ntfs"];

  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
  #environment.systemPackages = with pkgs; [ gnomeExtensions.appindicator ];
  services.udev.packages = with pkgs; [gnome.gnome-settings-daemon];

  hardware.opengl = {
    extraPackages = with pkgs; [mangohud];
    extraPackages32 = with pkgs; [mangohud];
  };

  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  boot.kernelPackages = pkgs.linuxPackages_zen;
  #boot.extraModulePackages = with config.boot.kernelPackages; [ bcachefs ];

  # Enable networking
  networking.networkmanager.enable = true;

  services.tailscale.enable = true;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.UTF-8";

  # Configure keymap in X11
  services.xserver = {
    layout = "us";
    xkbVariant = "alt-intl";
  };

  # Configure console keymap
  console.keyMap = "us";

  # # Enable CUPS to print documents.
  # services.printing.enable = true;

  # # Enable sound with pipewire.
  # sound.enable = true;
  # hardware.pulseaudio.enable = false;
  # security.rtkit.enable = true;
  # services.pipewire = {
  #   enable = true;
  #   alsa.enable = true;
  #   alsa.support32Bit = true;
  #   pulse.enable = true;
  # };

  services.netdata.enable = true;

  programs.gamemode.enable = true;

  fonts.packages = with pkgs; [
    (nerdfonts.override {fonts = ["FiraCode" "DroidSansMono" "CascadiaCode"];})
  ];

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.arosenfeld = {
    isNormalUser = true;
    description = "Alexandre Rosenfeld";
    extraGroups = ["networkmanager" "wheel"];
    packages = with pkgs; [
      appimage-run
      (appimage.appimagePackage {
        binName = "thorium";
        version = "117.0.5938.157";
        url = "https://github.com/Alex313031/thorium/releases/download/M117.0.5938.157/Thorium_Browser_117.0.5938.157_x64.AppImage";
        sha256 = "sha256-dlfClBbwSkQg4stKZdSgNg3EFsWksoI21cxRG5SMrOM=";
      })
    ];
  };

  # Enable automatic login for the user.
  #services.xserver.displayManager.autoLogin.enable = true;
  #services.xserver.displayManager.autoLogin.user = "arosenfeld";

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  #programs.steam.enable = true;
  #programs.steam.gamescopeSession.enable = true;

  hardware.opengl = {
    # this fixes the "glXChooseVisual failed" bug, context: https://github.com/NixOS/nixpkgs/issues/47932
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = ["arosenfeld"];
  };
  programs._1password.enable = true;

  environment.systemPackages = with pkgs; [
    vscode
    vim
    wget
    wineWowPackages.stable
    gamescope
    goverlay
    mangohud
    vkbasalt
    plex-mpv-shim

    gnome.gnome-tweaks
    gnome.gnome-terminal
    gnomeExtensions.appindicator
    gnomeExtensions.blur-my-shell
    gnomeExtensions.dash-to-dock

    materia-theme
    yaru-theme
    zuki-themes

    monitor

    pantheon.elementary-sound-theme
    pantheon.elementary-gtk-theme
    pantheon.elementary-icon-theme
  ];

  environment.variables = {
    MANGOHUD = "1";
  };

  services.flatpak = {
    enable = true;
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.05"; # Did you read the comment?
}
