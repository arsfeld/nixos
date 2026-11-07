# elementary Terminal 8.1.0 with its VTE widget replaced by gvt, the
# libghostty-vt widget in packages/gvt. gvt.patch says what it changes.
# Design: docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md
{
  lib,
  pantheon,
  fetchFromGitHub,
  gvt,
  vte-gtk4,
}:
pantheon.elementary-terminal.overrideAttrs (old: {
  # Pinned on every host: stable nixpkgs carries 8.0.0, unstable 8.1.0.
  version = "8.1.0";

  src = fetchFromGitHub {
    owner = "elementary";
    repo = "terminal";
    rev = "8.1.0";
    hash = "sha256-npPuanin2WKuIAVbvGwBf5fGHYp7LKGac+s+28apaLU=";
  };

  patches = (old.patches or []) ++ [./gvt.patch];

  buildInputs = lib.remove vte-gtk4 old.buildInputs ++ [gvt];

  # UnsafePasteTest, elementary's only test; it needs no display.
  doCheck = true;
})
