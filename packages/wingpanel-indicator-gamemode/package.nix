# Wingpanel indicator showing GameMode's state, macOS-style: a controller icon
# while gamemoded has a registered game, and a popover naming the game(s).
# Added to Pantheon by modules/desktop/pantheon-gamemode.nix.
# Design: docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md
{pkgs, ...}:
pkgs.stdenv.mkDerivation {
  pname = "wingpanel-indicator-gamemode";
  version = "0.1.0";

  # Only the sources, so editing this file or CLAUDE.md does not rebuild it.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [./meson.build ./src ./tests];
  };

  nativeBuildInputs = with pkgs; [meson ninja pkg-config vala];
  buildInputs = with pkgs; [glib gtk3 libgee pantheon.wingpanel];

  # Runs tests/TestNames.vala.
  doCheck = true;

  meta = {
    description = "GameMode indicator for Wingpanel";
    license = pkgs.lib.licenses.gpl3Plus;
    platforms = pkgs.lib.platforms.linux;
  };
}
