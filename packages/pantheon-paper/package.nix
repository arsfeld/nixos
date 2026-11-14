# PaperWM-style scrolling tiling for Pantheon, as a Gala plugin, with a
# Wingpanel indicator (lib/wingpanel) and a Tiling page for System Settings
# (a Switchboard plug, lib/switchboard-3/personal). Source:
# github.com/arsfeld/pantheon-paper. Design:
# docs/superpowers/specs/2026-11-12-pantheon-paper-design.md, and for the
# indicator and the page docs/superpowers/specs/2026-11-14-pantheon-paper-indicator-design.md.
#
# The plugin is built against the mutter gala itself uses (48), not the
# top-level one, the same way as packages/pantheon-global-menu. The unit tests
# (meson test, the indicator's and the plug's models included) run in
# checkPhase, so a failing test fails the host build.
# Added to Pantheon by modules/desktop/pantheon-paper.nix.
{pkgs, ...}: let
  inherit (pkgs.pantheon) gala;
  mutter = pkgs.lib.findFirst (d: pkgs.lib.hasPrefix "mutter-" d.name) null gala.buildInputs;
in
  pkgs.stdenv.mkDerivation {
    pname = "pantheon-paper";
    version = "0-unstable-2026-11-14";

    src = pkgs.fetchFromGitHub {
      owner = "arsfeld";
      repo = "pantheon-paper";
      rev = "38d159190c82e491046fe4669d74b8f0d5e85b3c";
      hash = "sha256-waybU8rGdBs+ltnU5je/PzEV6pAB6gZ4mBG1P71AO5Q=";
    };

    nativeBuildInputs = with pkgs; [meson ninja pkg-config vala glib];
    # The public Requires of libmutter-16, mutter-clutter-16 and mutter-cogl-16:
    # pkg-config needs them all to generate cflags.
    buildInputs = with pkgs; [
      glib
      libgee
      gdk-pixbuf
      pango
      cairo
      atk
      graphene
      pixman
      wayland
      libGL
      libx11
      libxfixes
      libxi
      gsettings-desktop-schemas
      gala
      mutter
      # The indicator (GTK 3) and the plug (GTK 4).
      gtk3
      pantheon.granite
      pantheon.wingpanel
      gtk4
      pantheon.granite7
      libadwaita
      pantheon.switchboard
    ];

    doCheck = true;

    meta = {
      description = "PaperWM-style scrolling tiling for Pantheon (Gala plugin)";
      homepage = "https://github.com/arsfeld/pantheon-paper";
      license = pkgs.lib.licenses.gpl3Plus;
      platforms = pkgs.lib.platforms.linux;
    };
  }
