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
    version = "0-unstable-2026-11-14";

    src = pkgs.fetchFromGitHub {
      owner = "arsfeld";
      repo = "pantheon-paper";
      rev = "556537342e5e509b96c909fcd3eab76bfdd552c5";
      hash = "sha256-Ho/kGv4IwTe4X7bOjigp25vUoCggYQXnbDgBik8vDB8=";
    };

    nativeBuildInputs = with pkgs; [meson ninja pkg-config vala glib];
    # The Wingpanel indicator and Switchboard plug are not wired into Pantheon
    # yet (docs/superpowers/plans/2026-11-14-pantheon-paper-indicator.md, the
    # packaging task): until then only the Gala plugin is built.
    mesonFlags = ["-Dindicator=false" "-Dplug=false"];
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
