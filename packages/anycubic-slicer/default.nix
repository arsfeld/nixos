{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchurl;
in
  stdenv.mkDerivation rec {
    pname = "anycubic-slicer-next";
    version = "1.3.7171";

    src = fetchurl {
      url = "https://cdn-universe-slicer.anycubic.com/prod/dists/noble/main/binary-amd64/AnycubicSlicerNext-${version}_20250928_162543-Ubuntu_24_04_2_LTS.deb";
      sha256 = "a01fe863cc4efe8f943974782bfcb2d1d008ae3077ced065f63db893d71e1f92";
    };

    nativeBuildInputs = with pkgs; [
      dpkg
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = with pkgs; [
      stdenv.cc.cc.lib
      gtk3
      glib
      webkitgtk_4_1
      cairo
      pango
      atk
      gdk-pixbuf
      libsoup_3
      libnotify
      libappindicator-gtk3
      xorg.libX11
      xorg.libXrandr
      xorg.libXext
      xorg.libXi
      xorg.libXtst
      xorg.libXcursor
      xorg.libXdamage
      xorg.libXfixes
      xorg.libXcomposite
      mesa
      libGL
      libGLU
      nspr
      nss
      cups
      dbus
      expat
      zlib
      alsa-lib
      fontconfig
      freetype
      at-spi2-atk
      at-spi2-core
      libdrm
      libxkbcommon
      wayland
    ];

    unpackPhase = ''
      dpkg-deb -x $src .
    '';

    installPhase = ''
            mkdir -p $out

            # Copy usr contents
            if [ -d usr ]; then
              cp -r usr/* $out/
            fi

            # Make the binary executable
            if [ -f $out/bin/AnycubicSlicerNext ]; then
              chmod +x $out/bin/AnycubicSlicerNext
            fi

            # Fix paths in desktop file if it exists
            if [ -f $out/share/applications/AnycubicSlicer.desktop ]; then
              substituteInPlace $out/share/applications/AnycubicSlicer.desktop \
                --replace /usr/bin/AnycubicSlicerNext $out/bin/anycubic-slicer \
                --replace /usr $out
            fi

            # The binary uses /proc/self/exe to find resources relative to itself.
            # With makeWrapper, /proc/self/exe points to bash so resolution fails.
            # Fix: place the real binary at $out/share/AnycubicSlicerNext/bin/ so that
            # going up one dir finds share/AnycubicSlicerNext/resources/.
            # Then use a manual wrapper script that sets env and exec's the binary.
            mkdir -p $out/share/AnycubicSlicerNext/bin
            mv $out/bin/AnycubicSlicerNext $out/share/AnycubicSlicerNext/bin/AnycubicSlicerNext
            chmod +x $out/share/AnycubicSlicerNext/bin/AnycubicSlicerNext

            # Create a manual wrapper script
            mkdir -p $out/bin
            cat > $out/bin/anycubic-slicer <<'WRAPPER'
      #!/bin/sh
      WRAPPER
            # Append the dynamic parts
            echo "export LD_LIBRARY_PATH=\"${lib.makeLibraryPath buildInputs}:/run/opengl-driver/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"" >> $out/bin/anycubic-slicer
            echo "exec $out/share/AnycubicSlicerNext/bin/AnycubicSlicerNext \"\$@\"" >> $out/bin/anycubic-slicer
            chmod +x $out/bin/anycubic-slicer
    '';

    meta = with lib; {
      description = "Anycubic Slicer Next - 3D printing slicer based on OrcaSlicer";
      homepage = "https://www.anycubic.com";
      platforms = ["x86_64-linux"];
      maintainers = [];
    };
  }
