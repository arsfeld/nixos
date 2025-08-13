# Desktop environment configuration module
#
# This module provides a compatibility layer that uses the constellation.gnome module
# for desktop environment setup. It maintains backward compatibility while delegating
# to the more modular constellation system.
#
# Features provided by constellation.gnome:
# - GNOME desktop environment with GDM display manager
# - Hardware acceleration support with 32-bit compatibility
# - Flatpak integration with pre-configured applications
# - Gaming support (Steam, Wine, emulators, game launchers)
# - Multimedia codecs via GStreamer plugins
# - Printing support with HP and Samsung drivers
# - Curated font collection for international support
# - GNOME extensions and theming options
# - Virtual machine management tools
{
  config,
  lib,
  ...
}: {
  options.desktop = {
    enable = lib.mkEnableOption "full desktop environment with GNOME and essential applications";
  };

  config = lib.mkIf config.desktop.enable {
    # Use constellation.gnome for the full desktop stack
    constellation.gnome = {
      enable = true;
      gnomeExtensions = true;
      gaming = true;
      multimedia = true;
      virtualization = true;
      # Keep the default flatpak packages from constellation.gnome
    };
  };
}
