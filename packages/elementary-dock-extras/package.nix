# elementary's dock with our extras: folder stacks, zoom, and icons that stay
# sharp while zoomed or tilted. Source: the `extras` branch of
# github.com/arsfeld/elementary-dock, a fork of elementary/dock with one commit
# per feature on top of the release, kept upstreamable but not proposed
# upstream. Its CI also publishes it to arsfeld.github.io/pantheon-extras as
# io.elementary.dock-extras for elementary OS. Rebase that branch onto a new
# elementary release and bump rev here; `just update-packages` follows the
# branch. modules/desktop/pantheon-dock puts it in place of
# pantheon.elementary-dock, calling this with the pantheon scope it overrides.
# Design: docs/superpowers/specs/2026-11-13-elementary-dock-extras-design.md
{
  pantheon,
  fetchFromGitHub,
}:
pantheon.elementary-dock.overrideAttrs {
  version = "8.3.3-unstable-2026-11-13";

  src = fetchFromGitHub {
    owner = "arsfeld";
    repo = "elementary-dock";
    rev = "b5d2dbfa5b6037db0e57d194be77e642b2083ef0";
    hash = "sha256-VV67+DqSZudXDb181YfFepuaHLxC0V743Mp6iKz9Bv8=";
  };

  # The extras' unit tests: stacks, zoom-math, icon-math. None needs a display.
  doCheck = true;
}
