{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub makeDesktopItem copyDesktopItems;
in
  stdenv.mkDerivation rec {
    pname = "librepods";
    version = "0.1.0-rc.4";

    src = fetchFromGitHub {
      owner = "kavishdevar";
      repo = "librepods";
      rev = "v${version}";
      hash = "sha256-FnDYQ3EPx2hpeCCZvbf5PJo+KCj+YO+DNg+++UpZ7Xs=";
    };

    sourceRoot = "source/linux";

    nativeBuildInputs = with pkgs; [
      cmake
      pkg-config
      qt6.wrapQtAppsHook
      copyDesktopItems
    ];

    buildInputs = with pkgs; [
      qt6.qtbase
      qt6.qtconnectivity
      qt6.qtdeclarative
      qt6.qttools
      openssl
    ];

    desktopItems = [
      (makeDesktopItem {
        name = "librepods";
        exec = "librepods";
        icon = "librepods";
        desktopName = "LibrePods";
        genericName = "AirPods Client";
        comment = "Open-source AirPods client for Linux";
        categories = ["Audio" "AudioVideo" "Settings" "HardwareSettings"];
        keywords = ["airpods" "bluetooth" "audio" "headphones"];
      })
    ];

    # The application needs the phone's Bluetooth MAC address
    # This can be set at runtime via environment variable
    postInstall = ''
      # Rename the binary to librepods
      mv $out/bin/applinux $out/bin/.librepods-unwrapped

      # Install icon (we're in the build directory, go back to source)
      install -Dm644 $src/linux/assets/airpods.png $out/share/icons/hicolor/256x256/apps/librepods.png

      # Create a wrapper script that prompts for MAC address if not set
      cat > $out/bin/librepods << EOF
      #!/usr/bin/env bash
      if [ -z "\$PHONE_MAC_ADDRESS" ]; then
        echo "Please set PHONE_MAC_ADDRESS environment variable to your phone's Bluetooth MAC address"
        echo "Example: export PHONE_MAC_ADDRESS='XX:XX:XX:XX:XX:XX'"
        echo ""
        echo "You can find your phone's Bluetooth MAC address in:"
        echo "  - iPhone: Settings > General > About > Bluetooth"
        echo "  - Android: Settings > About Phone > Status > Bluetooth address"
        exit 1
      fi
      exec $out/bin/.librepods-unwrapped "\$@"
      EOF

      chmod +x $out/bin/librepods
    '';

    meta = with lib; {
      description = "Open-source AirPods client for Linux";
      homepage = "https://github.com/kavishdevar/librepods";
      license = licenses.gpl3Only;
      platforms = platforms.linux;
      mainProgram = "librepods";
    };
  }
