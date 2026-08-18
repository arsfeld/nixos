# Advanced font configuration for optimal rendering
# Configured for macOS typography (SF Pro, SF Mono, New York)
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  appleFontPkgs = inputs.apple-fonts.packages.${pkgs.stdenv.hostPlatform.system};
in {
  fonts.packages = [
    appleFontPkgs.sf-pro
    appleFontPkgs.sf-compact
    appleFontPkgs.sf-mono-nerd
    appleFontPkgs.ny
  ];

  # User-specific fontconfig and dconf font settings
  home-manager.users.arosenfeld = {pkgs, ...}: {
    # Custom fontconfig configuration
    xdg.configFile."fontconfig/conf.d/10-hinting.conf".text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <!-- Hinting settings for better rendering -->
        <match target="font">
          <edit name="hinting" mode="assign">
            <bool>true</bool>
          </edit>
          <edit name="autohint" mode="assign">
            <bool>false</bool>
          </edit>
          <edit name="hintstyle" mode="assign">
            <const>hintslight</const>
          </edit>
        </match>
      </fontconfig>
    '';

    xdg.configFile."fontconfig/conf.d/20-subpixel.conf".text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <!-- Standard antialiasing (grayscale) without subpixel rendering matching macOS -->
        <match target="font">
          <edit name="rgba" mode="assign">
            <const>none</const>
          </edit>
          <edit name="lcdfilter" mode="assign">
            <const>none</const>
          </edit>
        </match>
      </fontconfig>
    '';

    xdg.configFile."fontconfig/conf.d/30-antialiasing.conf".text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <!-- Enable antialiasing for all fonts -->
        <match target="font">
          <edit name="antialias" mode="assign">
            <bool>true</bool>
          </edit>
        </match>

        <!-- Disable antialiasing for very small fonts -->
        <match target="font">
          <test name="size" compare="less">
            <double>8</double>
          </test>
          <edit name="antialias" mode="assign">
            <bool>false</bool>
          </edit>
        </match>
      </fontconfig>
    '';

    xdg.configFile."fontconfig/conf.d/50-font-replacements.conf".text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <!-- Replace standard fonts with Apple San Francisco and New York -->
        <alias>
          <family>Helvetica</family>
          <prefer>
            <family>SF Pro Display</family>
            <family>SF Pro Text</family>
            <family>SF Pro</family>
            <family>Inter</family>
            <family>Noto Sans</family>
          </prefer>
        </alias>

        <alias>
          <family>Arial</family>
          <prefer>
            <family>SF Pro Text</family>
            <family>SF Pro</family>
            <family>Inter</family>
            <family>Liberation Sans</family>
          </prefer>
        </alias>

        <alias>
          <family>Times New Roman</family>
          <prefer>
            <family>New York</family>
            <family>Liberation Serif</family>
            <family>Noto Serif</family>
          </prefer>
        </alias>

        <alias>
          <family>Courier New</family>
          <prefer>
            <family>SF Mono</family>
            <family>JetBrains Mono</family>
            <family>Cascadia Code</family>
          </prefer>
        </alias>

        <!-- Generic font families -->
        <alias>
          <family>sans-serif</family>
          <prefer>
            <family>SF Pro Text</family>
            <family>SF Pro Display</family>
            <family>SF Pro</family>
            <family>Inter</family>
            <family>Noto Sans</family>
          </prefer>
        </alias>

        <alias>
          <family>serif</family>
          <prefer>
            <family>New York</family>
            <family>Noto Serif</family>
            <family>Liberation Serif</family>
          </prefer>
        </alias>

        <alias>
          <family>monospace</family>
          <prefer>
            <family>SF Mono</family>
            <family>JetBrains Mono</family>
            <family>Cascadia Code</family>
          </prefer>
        </alias>

        <!-- Prefer color emoji -->
        <alias>
          <family>emoji</family>
          <prefer>
            <family>Noto Color Emoji</family>
          </prefer>
        </alias>
      </fontconfig>
    '';

    # GNOME-specific font settings via dconf
    #
    # Sizes are tuned to match macOS on the shared 34" 3440x1440 panel (scale 1,
    # no HiDPI on either side). GTK converts points at a fixed 96 DPI, so 10pt
    # renders at 13.3px -- macOS draws its system UI at 13px. Keep
    # text-scaling-factor at 1.0: Firefox and Chrome derive their default page
    # zoom from it, so scaling here would shrink web content below macOS's 1:1.
    dconf.settings = {
      "org/gnome/desktop/interface" = {
        font-name = "SF Pro Text 10";
        document-font-name = "SF Pro Text 10";
        monospace-font-name = "SF Mono 10";
        font-antialiasing = "grayscale";
        font-hinting = "slight";
        text-scaling-factor = 1.0;
        cursor-theme = "WhiteSur-cursors";
        cursor-size = 24;
      };

      "org/gnome/desktop/wm/preferences" = {
        titlebar-font = "SF Pro Display Bold 10";
        button-layout = "close,minimize,maximize:";
      };
    };
  };
}
