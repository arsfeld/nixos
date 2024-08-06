{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  appimage = pkgs.callPackage (import ./appimage.nix) {};
in {
  imports = self.nixosSuites.raider ++ [./hardware-configuration.nix];

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

  services.system76-scheduler.enable = true;

  networking.hostName = "raider-nixos";

  systemd.services.NetworkManager-wait-online.enable = false;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Remove zfs
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

  virtualisation.podman.enable = true;
  virtualisation.podman.dockerCompat = true;

  services.xserver.enable = true;

  services.xserver.displayManager.gdm.enable = lib.mkDefault true;
  services.xserver.desktopManager.gnome.enable = lib.mkDefault true;
  services.udev.packages = with pkgs; [gnome.gnome-settings-daemon];

  services.displayManager.defaultSession = "gnome";

  services.xserver.desktopManager.gnome = {
    extraGSettingsOverridePackages = [pkgs.gnome.mutter];
    extraGSettingsOverrides = ''
      [org.gnome.mutter]
      experimental-features=['variable-refresh-rate']
    '';
  };

  hardware.graphics = {
    extraPackages = with pkgs; [mangohud];
    extraPackages32 = with pkgs; [mangohud];
  };

  boot.kernelPackages = pkgs.linuxPackages_zen;

  networking.networkmanager.enable = true;

  programs.coolercontrol.enable = true;

  services.tailscale.enable = true;

  services.power-profiles-daemon.enable = false;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.UTF-8";

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "alt-intl";
  };

  #chaotic.mesa-git.enable = true;
  #chaotic.appmenu-gtk3-module.enable = true;

  # Configure console keymap
  console.keyMap = "us";

  # # Enable CUPS to print documents.
  services.printing.enable = true;
  services.printing.drivers = [pkgs.hplipWithPlugin pkgs.samsung-unified-linux-driver];

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.netdata.enable = true;

  # programs.gamemode.enable = true;

  fonts.packages = with pkgs; [
    (nerdfonts.override {fonts = ["FiraCode" "DroidSansMono" "CascadiaCode"];})

    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    liberation_ttf
    source-han-sans-japanese
    source-han-serif-japanese

    cascadia-code
  ];

  # Enable automatic login for the user.
  #services.xserver.displayManager.autoLogin.enable = true;
  #services.xserver.displayManager.autoLogin.user = "arosenfeld";

  programs.steam.enable = true;
  programs.steam.gamescopeSession.enable = true;

  hardware.graphics = {
    # this fixes the "glXChooseVisual failed" bug, context: https://github.com/NixOS/nixpkgs/issues/47932
    enable = true;
    enable32Bit = true;
  };

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = ["arosenfeld"];
  };
  programs._1password.enable = true;

  environment.systemPackages = with pkgs; [
    #vscode
    vim
    wget
    wineWowPackages.stable
    gamescope
    goverlay
    mangohud
    vkbasalt
    plex-mpv-shim
    mission-center
    variety
    bottles
    protonplus
    quickemu
    quickgui
    multiviewer-for-f1
    lutris
    cartridges
    ryujinx
    mupen64plus
    rpcs3
    celluloid

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

    virtualboxKvm

    #blackbox-terminal
    ptyxis

    gradience
    gnome-extension-manager
    gnome-tweaks
    gnomeExtensions.appindicator
    gnomeExtensions.blur-my-shell
    gnomeExtensions.dash-to-dock
    gnomeExtensions.gsnap
    gnomeExtensions.system76-scheduler
    gnomeExtensions.gsconnect
    gnomeExtensions.gtile
    gnomeExtensions.xwayland-indicator
    gnomeExtensions.vitals
    gnomeExtensions.window-gestures
    gnomeExtensions.user-themes

    #qogir-theme
    #materia-theme
    yaru-theme
    #zuki-themes
    #tela-icon-theme
    #tela-circle-icon-theme
    #vimix-icon-theme
    #qogir-icon-theme
    #papirus-icon-theme
    #morewaita-icon-theme
    #moka-icon-theme
    colloid-icon-theme
    colloid-gtk-theme
    #orchis-theme

    pantheon.elementary-sound-theme
    pantheon.elementary-gtk-theme
    pantheon.elementary-icon-theme
    pantheon.elementary-wallpapers
  ];

  environment.gnome.excludePackages =
    (with pkgs; [
      gnome-photos
      gnome-tour
      gnome-console
      gnome-terminal
      gnome-system-monitor
      geary
      evince
      totem
    ])
    ++ (with pkgs.gnome; [
      gnome-music
      gnome-shell-extensions
      tali # poker game
      iagno # go game
      hitori # sudoku game
      atomix # puzzle game
    ]);

  nixpkgs.overlays = [
    # (final: prev: let
    #   aurRepo = pkgs.fetchgit {
    #     url = "https://aur.archlinux.org/libadwaita-without-adwaita-git.git";
    #     rev = "444b58f612c50a3570fc9b8370a299be2bcf6bda";
    #     hash = "sha256-8qfIlmTAQpjmzGtl6CdWscoeFNk7YpfoutVLkilDATk=";
    #   };
    #   themingPatch = aurRepo + "/theming_patch.diff";
    # in {
    #   libadwaita = prev.libadwaita.overrideAttrs (old: {
    #     doCheck = false;
    #     patches =
    #       (old.patches or [])
    #       ++ [
    #         themingPatch
    #       ];
    #   });
    # })

    # (self: super: let
    #   id = "168727396";
    # in {
    #   multiviewer-for-f1 = super.multiviewer-for-f1.overrideAttrs (old: rec {
    #     version = "1.32.1";

    #     src = super.fetchurl {
    #       url = "https://releases.multiviewer.dev/download/${id}/multiviewer-for-f1_${version}_amd64.deb";
    #       sha256 = "sha256-cnfye5c3+ZYZLjlZ6F4OD90tXhxDbgbNBn98mgmZ+Hs=";
    #     };
    #   });
    # })

    # GNOME 46: triple-buffering-v4-46
    # (final: prev: {
    #   gnome = prev.gnome.overrideScope (gnomeFinal: gnomePrev: {
    #     mutter = gnomePrev.mutter.overrideAttrs (old: {
    #       src = pkgs.fetchFromGitLab {
    #         domain = "gitlab.gnome.org";
    #         owner = "vanvugt";
    #         repo = "mutter";
    #         rev = "triple-buffering-v4-46";
    #         hash = "sha256-nz1Enw1NjxLEF3JUG0qknJgf4328W/VvdMjJmoOEMYs=";
    #       };
    #     });
    #   });
    # })
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
