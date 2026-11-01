# nixpkgs' copy stalls: MultiViewer's release API now returns `id = null` and
# tokenised URLs, which its updateScript can't follow. `just update-packages`
# bumps this one from the API instead.
{
  stdenvNoCC,
  fetchurl,
  lib,
  makeWrapper,
  autoPatchelfHook,
  dpkg,
  alsa-lib,
  at-spi2-atk,
  cairo,
  cups,
  dbus,
  expat,
  ffmpeg,
  glib,
  gtk3,
  libdrm,
  libudev0-shim,
  libxkbcommon,
  libgbm,
  nspr,
  nss,
  pango,
  libxrandr,
  libxfixes,
  libxext,
  libxdamage,
  libxcomposite,
  libx11,
  libxcb,
}: let
  # Per-release download token from the release API; not derivable from the version.
  token = "4v6Nh56coT9pCM00V7Cr45AfiwX9PG-F";
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "multiviewer-for-f1";
    version = "2.13.0";

    src = fetchurl {
      url = "https://releases.multiviewer.app/v/${finalAttrs.version}/1/${token}/multiviewer_${finalAttrs.version}_amd64.deb";
      hash = "sha256-JE5xsOUk2VZ2AdZP9IV9OU3Sm6jnc0hAO66KtwhHn/s=";
    };

    nativeBuildInputs = [
      dpkg
      makeWrapper
      autoPatchelfHook
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      cairo
      cups
      dbus
      expat
      ffmpeg
      glib
      gtk3
      libdrm
      libxkbcommon
      libgbm
      nspr
      nss
      pango
      libx11
      libxcomposite
      libxcb
      libxdamage
      libxext
      libxfixes
      libxrandr
    ];

    dontBuild = true;
    dontConfigure = true;

    unpackPhase = ''
      runHook preUnpack

      # The deb file contains a setuid binary, so 'dpkg -x' doesn't work here
      dpkg --fsys-tarfile $src | tar --extract

      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/share
      mv -t $out/share usr/share/* usr/lib/multiviewer

      makeWrapper "$out/share/multiviewer/multiviewer" $out/bin/multiviewer \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [libudev0-shim]}:\"$out/share/multiviewer\""

      runHook postInstall
    '';

    meta = {
      description = "Unofficial desktop client for F1 TV";
      homepage = "https://multiviewer.app";
      downloadPage = "https://multiviewer.app/download";
      license = lib.licenses.unfree;
      platforms = ["x86_64-linux"];
      mainProgram = "multiviewer";
    };
  })
