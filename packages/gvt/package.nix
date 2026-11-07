# gvt: a GTK4 terminal widget on libghostty-vt, with VTE's API, so that
# elementary Terminal can be ported off VTE by a rename. Source:
# github.com/arsfeld/gvt, our own project, kept upstreamable; it tracks master
# through `just update-packages`. Its API moves in lockstep with the `gvt`
# branch of github.com/arsfeld/elementary-terminal
# (packages/elementary-terminal-ghostty), so bump the two together.
# Design: docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md
{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  vala,
  pkg-config,
  wrapGAppsNoGuiHook,
  glib,
  gtk4,
  pango,
  libghostty-vt-1,
  weston,
  makeFontsConf,
  dejavu_fonts,
}:
stdenv.mkDerivation {
  pname = "gvt";
  version = "0.1.0-unstable-2026-11-07";

  src = fetchFromGitHub {
    owner = "arsfeld";
    repo = "gvt";
    rev = "7a55eba825f293a1f7e9101a8e3287d42c37a8a8";
    hash = "sha256-TE0HRHAyjdD8qTH5LgD93eiyQWLIjNbJ1q8OX9txGkY=";
  };

  strictDeps = true;
  nativeBuildInputs = [meson ninja vala pkg-config glib wrapGAppsNoGuiHook];
  buildInputs = [glib gtk4 pango libghostty-vt-1];

  doCheck = true;
  nativeCheckInputs = [weston];
  # Shows each test's TAP lines in the build log.
  mesonCheckFlags = ["--verbose"];

  # Every test runs against a headless compositor, including the ones that
  # need no display, so a test that grows a widget later needs no change here.
  preCheck = ''
    export XDG_RUNTIME_DIR=$TMPDIR
    chmod 0700 "$XDG_RUNTIME_DIR"
    # One known monospace font, so the widget tests' cell metrics are stable.
    export FONTCONFIG_FILE=${makeFontsConf {fontDirectories = [dejavu_fonts];}}
    export XDG_CACHE_HOME=$TMPDIR/cache
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

  # GLib reads only gschemas.compiled from each XDG_DATA_DIRS entry, so the
  # schema an app's wrapper points at must ship compiled, as gtk4's does.
  # postFixup, because glib's preFixup hook is what moves the schema here.
  postFixup = ''
    glib-compile-schemas "$out/share/gsettings-schemas/$name/glib-2.0/schemas"
  '';

  meta = {
    description = "GTK4 terminal widget on libghostty-vt, with VTE's API";
    homepage = "https://github.com/arsfeld/gvt";
    license = lib.licenses.gpl3Plus;
    pkgConfigModules = ["gvt-1"];
    platforms = lib.platforms.linux;
  };
}
