# elementary Terminal 8.1.0 with its VTE widget replaced by libghostty-gtk, the
# libghostty-vt widget in packages/libghostty-gtk. Source: the `libghostty-gtk` branch of
# github.com/arsfeld/elementary-terminal, a fork of elementary/terminal whose
# commits on top of the release are the port, kept upstreamable. Rebase that
# branch onto a new elementary release and bump rev here; `just
# update-packages` follows the branch.
# Design: docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md
{
  lib,
  pantheon,
  fetchFromGitHub,
  libghostty-gtk,
  vte-gtk4,
}:
pantheon.elementary-terminal.overrideAttrs (old: {
  # Pinned on every host: stable nixpkgs carries 8.0.0, unstable 8.1.0.
  version = "8.1.0-unstable-2026-11-07";

  src = fetchFromGitHub {
    owner = "arsfeld";
    repo = "elementary-terminal";
    rev = "72ff1b92fa41863e46585d68cb1c8ed73fb0e3be";
    hash = "sha256-o5k7u4eAKjMpQLWhGAR12/SjhiXEWhQ1EAEVDbA8tRk=";
  };

  buildInputs = lib.remove vte-gtk4 old.buildInputs ++ [libghostty-gtk];

  # UnsafePasteTest, elementary's only test; it needs no display.
  doCheck = true;
})
