# Anthropic's official Claude Desktop for Linux (beta), repackaged from the
# .deb in their apt repo. To bump: read the newest Version/SHA256 pair from
# https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages
{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchurl;

  # dlopen()ed at runtime, so autoPatchelf can't see them.
  runtimeLibs = with pkgs; [
    libGL
    libnotify
    libsecret
    libappindicator-gtk3
    pipewire
    systemd
    vulkan-loader
  ];
in
  stdenv.mkDerivation rec {
    pname = "claude-desktop";
    version = "2.9939.4";

    src = fetchurl {
      url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
      sha256 = "3cfddb23bf2911e05e27b4ed3856b8e795df94643b2c35b59deb317cf995bca0";
    };

    nativeBuildInputs = with pkgs; [
      dpkg
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = with pkgs;
      [
        stdenv.cc.cc.lib
        alsa-lib
        at-spi2-atk
        at-spi2-core
        cairo
        cups
        dbus
        expat
        glib
        gtk3
        libdrm
        libgbm
        libxkbcommon
        nspr
        nss
        pango
        libx11
        libxcomposite
        libxdamage
        libxext
        libxfixes
        libxrandr
        libxtst
        libxcb
        libuuid
        libcap_ng
        libseccomp
      ]
      ++ runtimeLibs;

    unpackPhase = ''
      # The sandbox can't keep its setuid bit, so --no-same-permissions.
      dpkg-deb --fsys-tarfile $src | tar -x --no-same-permissions
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/lib
      cp -r usr/lib/claude-desktop $out/lib/
      cp -r usr/share $out/

      # A setuid helper can't live in the store; NixOS has unprivileged user
      # namespaces, so Chromium falls back to its namespace sandbox.
      rm $out/lib/claude-desktop/chrome-sandbox

      makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs} \
        --prefix PATH : ${lib.makeBinPath [pkgs.xdg-utils]} \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

      runHook postInstall
    '';

    meta = {
      description = "Official Claude desktop app (Chat, Cowork, Code)";
      homepage = "https://claude.ai";
      license = lib.licenses.unfree;
      platforms = ["x86_64-linux"];
      mainProgram = "claude-desktop";
    };
  }
