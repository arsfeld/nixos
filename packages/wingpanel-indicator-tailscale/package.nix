# Wingpanel indicator for Tailscale: an icon for tailscaled's state, always
# shown, and a popover with an on/off switch and an exit-node picker.
# Added to Pantheon by modules/desktop/pantheon-tailscale.nix.
# Design: docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md
{pkgs, ...}:
pkgs.stdenv.mkDerivation {
  pname = "wingpanel-indicator-tailscale";
  version = "0.1.0";

  # Only the sources, so editing this file or CLAUDE.md does not rebuild it.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [./meson.build ./src ./tests];
  };

  nativeBuildInputs = with pkgs; [meson ninja pkg-config vala];
  buildInputs = with pkgs; [glib gtk3 json-glib libgee libsoup_3 pantheon.granite pantheon.wingpanel];

  # Runs tests/TestModel.vala.
  doCheck = true;

  meta = {
    description = "Tailscale indicator for Wingpanel";
    license = pkgs.lib.licenses.gpl3Plus;
    platforms = pkgs.lib.platforms.linux;
  };
}
