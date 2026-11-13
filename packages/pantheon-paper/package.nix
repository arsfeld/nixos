# PaperWM-style scrolling tiling for Pantheon, as a Gala plugin. Source:
# github.com/arsfeld/pantheon-paper. Design:
# docs/superpowers/specs/2026-11-12-pantheon-paper-design.md.
#
# Built against the mutter gala itself uses (48), not the top-level one, the
# same way as packages/pantheon-global-menu. The unit tests (meson test) run in
# checkPhase, so a failing test fails the host build.
# Added to Pantheon by modules/desktop/pantheon-paper.nix.
{pkgs, ...}: let
  inherit (pkgs.pantheon) gala;
  mutter = pkgs.lib.findFirst (d: pkgs.lib.hasPrefix "mutter-" d.name) null gala.buildInputs;
in
  pkgs.stdenv.mkDerivation {
    pname = "pantheon-paper";
    version = "0-unstable-2026-11-13";

    src = pkgs.fetchFromGitHub {
      owner = "arsfeld";
      repo = "pantheon-paper";
      rev = "d9bcfdd5d21feebb91125b8cd977ea3689f71ef0";
      hash = "sha256-W3sfT4kWJp61nRzDG7XDpdR5b/mKw+F84IzNmOAbI/Y=";
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
    ];

    doCheck = true;

    meta = {
      description = "PaperWM-style scrolling tiling for Pantheon (Gala plugin)";
      homepage = "https://github.com/arsfeld/pantheon-paper";
      license = pkgs.lib.licenses.gpl3Plus;
      platforms = pkgs.lib.platforms.linux;
    };
  }
