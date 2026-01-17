# COSMIC Desktop Environment configuration for constellation
# Provides System76's COSMIC desktop with essential applications
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  options.constellation.cosmic = {
    enable = lib.mkEnableOption "COSMIC desktop environment";

    gaming = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable gaming support (Steam, Wine, gamescope)";
    };

    multimedia = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable multimedia codecs and GStreamer plugins";
    };

    flatpakPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "com.github.tchx84.Flatseal"
        "com.spotify.Client"
        "org.mozilla.firefox"
        "com.discordapp.Discord"
        "org.videolan.VLC"
        "app.zen_browser.zen"
      ];
      description = "Flatpak packages to install";
    };
  };

  config = lib.mkIf config.constellation.cosmic.enable (let
    cfg = config.constellation.cosmic;
    # Create unstable package set
    pkgs-unstable = import inputs.nixpkgs-unstable {
      system = pkgs.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  in {
    # COSMIC Desktop Environment
    services.desktopManager.cosmic.enable = true;
    services.displayManager.cosmic-greeter.enable = true;

    # Disable network manager wait
    systemd.services.NetworkManager-wait-online.enable = false;

    # Hardware graphics support with 32-bit compatibility
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Environment variables for Wayland
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1"; # Electron apps Wayland support
      MOZ_ENABLE_WAYLAND = "1"; # Firefox Wayland
    };

    # Essential desktop packages
    environment.systemPackages = with pkgs;
      [
        # Core applications
        pkgs-unstable.zed-editor
        pkgs-unstable.ghostty
        vim
        wget
      ]
      ++ lib.optionals cfg.gaming [
        # Gaming support
        wineWowPackages.stable
        gamescope
        goverlay
        vkbasalt
        protonplus
      ]
      ++ lib.optionals cfg.multimedia [
        # Multimedia support
        celluloid
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-plugins-ugly
        gst_all_1.gst-libav
        gst_all_1.gst-vaapi
      ];

    # Gaming hardware support
    hardware.steam-hardware.enable = lib.mkIf cfg.gaming true;

    # Flatpak support with configured packages
    services.flatpak = {
      enable = true;
      packages = cfg.flatpakPackages;
    };

    # Printing support
    services.printing = {
      enable = true;
      drivers = with pkgs; [hplipWithPlugin];
    };

    # Network discovery
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # Font configuration
    fonts = {
      fontconfig = {
        enable = true;
        antialias = true;
        cache32Bit = true;
        hinting = {
          enable = true;
          autohint = false;
          style = "slight";
        };
        subpixel = {
          rgba = "none";
          lcdfilter = "none";
        };
        defaultFonts = {
          serif = ["Noto Serif" "Liberation Serif" "DejaVu Serif"];
          sansSerif = ["Inter" "Noto Sans" "DejaVu Sans"];
          monospace = ["JetBrains Mono" "Cascadia Code" "Fira Code"];
          emoji = ["Noto Color Emoji"];
        };
      };

      packages = with pkgs; [
        inter
        jetbrains-mono
        roboto
        ubuntu-classic
        cantarell-fonts
        nerd-fonts.fira-code
        nerd-fonts.jetbrains-mono
        nerd-fonts.meslo-lg
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
        liberation_ttf
        dejavu_fonts
        freefont_ttf
        source-han-sans
        source-han-serif
        corefonts
        cascadia-code
        iosevka
        fira-code
      ];
    };
  });
}
