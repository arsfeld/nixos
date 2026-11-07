# gvt: a GTK4 terminal widget on libghostty-vt, with VTE's API, so that
# elementary Terminal can be ported off VTE by a patch.
# Design: docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md
{
  lib,
  stdenv,
  meson,
  ninja,
  vala,
  pkg-config,
  wrapGAppsNoGuiHook,
  glib,
  gtk4,
  pango,
  libghostty-vt,
  weston,
}:
stdenv.mkDerivation {
  pname = "gvt";
  version = "0.1.0";

  # Only the sources, so editing this file does not rebuild it.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./meson.build
      ./meson_options.txt
      ./gvt-1.deps
      ./src
      ./vapi
      ./data
      ./tests
    ];
  };

  strictDeps = true;
  nativeBuildInputs = [meson ninja vala pkg-config glib wrapGAppsNoGuiHook];
  buildInputs = [glib gtk4 pango libghostty-vt];

  doCheck = true;
  nativeCheckInputs = [weston];
  # Shows each test's TAP lines in the build log.
  mesonCheckFlags = ["--verbose"];

  # Every test runs against a headless compositor, including the ones that
  # need no display, so a test that grows a widget later needs no change here.
  preCheck = ''
    export XDG_RUNTIME_DIR=$TMPDIR
    chmod 0700 "$XDG_RUNTIME_DIR"
    weston --backend=headless --socket=gvt-test --idle-time=0 &
    westonPid=$!
    export WAYLAND_DISPLAY=gvt-test
    for _ in $(seq 100); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.1
    done
    [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || { echo "weston did not start"; exit 1; }
    export GSETTINGS_SCHEMA_DIR=$PWD/data
  '';
  postCheck = ''
    kill $westonPid
  '';

  meta = {
    description = "GTK4 terminal widget on libghostty-vt, with VTE's API";
    license = lib.licenses.gpl3Plus;
    pkgConfigModules = ["gvt-1"];
    platforms = lib.platforms.linux;
  };
}
