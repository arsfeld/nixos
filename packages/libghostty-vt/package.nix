{
  lib,
  stdenv,
  fetchurl,
  pkg-config,
  runCommandCC,
  unstable,
}: let
  zig = unstable.zig_0_17;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "libghostty-vt";
    version = "1.0.0";

    srcs = [
      (fetchurl {
        url = "https://release.files.ghostty.org/libghostty-vt/${finalAttrs.version}/libghostty-vt-${finalAttrs.version}.tar.gz";
        hash = "sha256-Sm73WL5yGSPhlp57gbRD3MktjdP7WjlgDAOogXp1NnY=";
      })
      (fetchurl {
        url = "https://release.files.ghostty.org/libghostty-vt/${finalAttrs.version}/libghostty-vt-${finalAttrs.version}-deps.tar.gz";
        hash = "sha256-TV6l5Ejkx+qPtVzLqoZo8ql9RPQ4zugx4rfs0WLYXCk=";
      })
    ];
    sourceRoot = "libghostty-vt-${finalAttrs.version}";

    strictDeps = true;
    nativeBuildInputs = [zig pkg-config];

    dontSetZigDefaultFlags = true;
    zigBuildFlags = [
      "--system"
      "../libghostty-vt-${finalAttrs.version}-deps"
      "-Doptimize=ReleaseFast"
      "-Dcpu=baseline"
    ];

    # A fresh, empty cache: a populated one can crash Zig with "reached
    # unreachable code" (PACKAGING-LIBGHOSTTY.md).
    preBuild = ''
      export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
    '';

    doCheck = false;

    outputs = ["out" "dev"];

    postInstall = ''
      mkdir -p "$dev/lib"
      mv "$out/lib/libghostty-vt.a" "$dev/lib/"
    '';

    postFixup = ''
      if [ -f "$dev/share/pkgconfig/libghostty-vt-static.pc" ]; then
        substituteInPlace "$dev/share/pkgconfig/libghostty-vt-static.pc" --replace-fail "$out" "$dev"
      fi
    '';

    passthru.tests.smoke =
      runCommandCC "libghostty-vt-smoke" {
        nativeBuildInputs = [pkg-config];
        buildInputs = [finalAttrs.finalPackage];
      } ''
        cc -o smoke ${./smoke.c} $(pkg-config --cflags --libs libghostty-vt)
        ./smoke
        touch $out
      '';

    meta = {
      description = "Ghostty's VT (terminal sequence) parsing library";
      homepage = "https://ghostty.org/";
      license = lib.licenses.mit;
      pkgConfigModules = ["libghostty-vt"];
      platforms = zig.meta.platforms;
    };
  })
