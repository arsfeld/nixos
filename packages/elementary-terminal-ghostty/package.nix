# elementary Terminal 8.1.0 with its VTE widget replaced by gvt, the
# libghostty-vt widget in packages/gvt. Source: the `gvt` branch of
# github.com/arsfeld/elementary-terminal, a fork of elementary/terminal whose
# commits on top of the release are the port, kept upstreamable. Rebase that
# branch onto a new elementary release and bump rev here; `just
# update-packages` follows the branch.
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
  version = "8.1.0-unstable-2026-11-07";

  src = fetchFromGitHub {
    owner = "arsfeld";
    repo = "elementary-terminal";
    rev = "f9f00a3ad7dbafe59ceb97019c534fc88095fd3a";
    hash = "sha256-UETJvLWsdbBGR7W3UHmUrD9SBrK9/o0DM/vx5+lOAPM=";
  };

  buildInputs = lib.remove vte-gtk4 old.buildInputs ++ [gvt];

  # UnsafePasteTest, elementary's only test; it needs no display.
  doCheck = true;
})
