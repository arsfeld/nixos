# Advanced font configuration for optimal rendering
# This provides additional per-user font configuration options
{
  config,
  pkgs,
  lib,
  ...
}: {
  # Optional: User-specific fontconfig for fine-tuning
  home-manager.users.arosenfeld = {pkgs, ...}: {
    # Create a custom fontconfig configuration
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
        <!-- Standard antialiasing (grayscale) without subpixel rendering -->
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
        <!-- Replace common Windows/Mac fonts with high-quality alternatives -->
        <alias>
          <family>Helvetica</family>
          <prefer>
            <family>Inter</family>
            <family>Noto Sans</family>
          </prefer>
        </alias>

        <alias>
          <family>Arial</family>
          <prefer>
            <family>Inter</family>
            <family>Liberation Sans</family>
          </prefer>
        </alias>

        <alias>
          <family>Times New Roman</family>
          <prefer>
            <family>Liberation Serif</family>
            <family>Noto Serif</family>
          </prefer>
        </alias>

        <alias>
          <family>Courier New</family>
          <prefer>
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
    dconf.settings = {
      "org/gnome/desktop/interface" = {
        font-name = "Inter 11";
        document-font-name = "Inter 11";
        monospace-font-name = "JetBrains Mono 10";
        font-antialiasing = "grayscale";
        font-hinting = "slight";
        text-scaling-factor = 1.0;
      };

      "org/gnome/desktop/wm/preferences" = {
        titlebar-font = "Inter Bold 11";
      };
    };
  };
}
