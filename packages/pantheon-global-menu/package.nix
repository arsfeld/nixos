# Pantheon global menu: the focused app's menus in Wingpanel, next to
# Applications. A Gala plugin (focus tracking, AppMenu registrar, typing
# shortcuts) plus a Wingpanel indicator; shortcut menus for apps that publish
# none come from orbit-global-menu's mappings, which the fork extends with
# elementary's apps. Source: github.com/arsfeld/pantheon-global-menu, a fork
# of Unmade760/orbit-global-menu; the port lives in its pantheon/.
#
# The derivation is repeated here rather than imported from the fetched tree's
# pantheon/package.nix: importing from a fetched source is
# import-from-derivation, which evaluation of this flake avoids.
# Added to Pantheon by modules/desktop/pantheon-globalmenu.nix.
{pkgs, ...}: let
  inherit (pkgs.pantheon) gala;
  # The mutter gala is built against (48), not the top-level one.
  mutter = pkgs.lib.findFirst (d: pkgs.lib.hasPrefix "mutter-" d.name) null gala.buildInputs;
in
  pkgs.stdenv.mkDerivation {
    pname = "pantheon-global-menu";
    version = "0-unstable-2026-11-05";

    src = pkgs.fetchFromGitHub {
      owner = "arsfeld";
      repo = "pantheon-global-menu";
      rev = "3b9cb8e78ba42d5c092791a43a1aab0c610370f4";
      hash = "sha256-xMm6mufDNkkgTyZfXG9kmVmoAJcpoH8OBOijaGtvSiE=";
    };

    sourceRoot = "source/pantheon";

    nativeBuildInputs = with pkgs; [meson ninja pkg-config vala];
    buildInputs = with pkgs; [glib gtk3 json-glib libgee libdbusmenu-gtk3 pantheon.granite pantheon.wingpanel gala mutter];

    meta = {
      description = "Global menu for Pantheon: the focused app's menus in Wingpanel";
      homepage = "https://github.com/arsfeld/pantheon-global-menu";
      license = pkgs.lib.licenses.gpl3Plus;
      platforms = pkgs.lib.platforms.linux;
    };
  }
