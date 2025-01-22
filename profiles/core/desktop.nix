{
  inputs,
  config,
  pkgs,
  lib,
  self,
  ...
}: {
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };

  # services.desktopManager.cosmic.enable = false;
  # services.displayManager.cosmic-greeter.enable = false;

  systemd.services.NetworkManager-wait-online.enable = false;

  services.flatpak = {
    enable = true;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [mangohud];
    extraPackages32 = with pkgs; [mangohud];
  };

  # # Enable CUPS to print documents.
  services.printing.enable = true;
  services.printing.drivers = [pkgs.hplipWithPlugin pkgs.samsung-unified-linux-driver];

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  fonts = {
    fontconfig = {
      antialias = true;
      cache32Bit = true;
      hinting.enable = true;
      hinting.autohint = true;
    };

    packages = with pkgs; [
      nerd-fonts.fira-code
      nerd-fonts.droid-sans-mono

      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-emoji
      liberation_ttf
      source-han-sans-japanese
      source-han-serif-japanese

      cascadia-code
    ];
  };

  hardware.steam-hardware.enable = true;

  programs.virt-manager.enable = true;

  services.flatpak = {
    packages = [
      "com.valvesoftware.Steam"
      "com.github.tchx84.Flatseal"
      "com.spotify.Client"
      "tv.plex.PlexDesktop"
      "org.mozilla.firefox"
      "com.discordapp.Discord"
      "org.libreoffice.LibreOffice"
      "engineer.atlas.Nyxt"
      "com.visualstudio.code"
      "org.videolan.VLC"
      "com.usebottles.bottles"
      "net.lutris.Lutris"
      "app.devsuite.Ptyxis"
    ];
  };

  environment.systemPackages = with pkgs; [
    zed-editor
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
    protonplus
    quickemu
    #quickgui
    multiviewer-for-f1
    #cartridges
    ryujinx
    mupen64plus
    rpcs3
    celluloid
    ghostty

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
    #gnome-extension-manager
    gnome-tweaks
    gnomeExtensions.appindicator
    gnomeExtensions.blur-my-shell
    gnomeExtensions.dash-to-dock
    gnomeExtensions.wallpaper-slideshow
    gnomeExtensions.gsconnect
    gnomeExtensions.gtile
    gnomeExtensions.xwayland-indicator
    gnomeExtensions.vitals
    gnomeExtensions.window-gestures
    gnomeExtensions.user-themes
    gnomeExtensions.tiling-shell

    #qogir-theme
    #materia-theme
    #zuki-themes
    #tela-icon-theme
    #tela-circle-icon-theme
    #vimix-icon-theme
    #qogir-icon-theme
    #papirus-icon-theme
    #morewaita-icon-theme
    #moka-icon-theme
    #orchis-theme

    yaru-theme
    colloid-icon-theme
    colloid-gtk-theme

    pantheon.elementary-sound-theme
    pantheon.elementary-gtk-theme
    pantheon.elementary-icon-theme
    pantheon.elementary-wallpapers
  ];

  environment.gnome.excludePackages = with pkgs; [
    gnome-music
    gnome-photos
    gnome-tour
    gnome-console
    gnome-terminal
    gnome-system-monitor
    geary
    evince
    totem
    tali
    hitori
    atomix
    iagno
  ];
}
