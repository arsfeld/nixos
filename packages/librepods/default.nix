{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub;
in
  stdenv.mkDerivation rec {
    pname = "librepods";
    version = "1.0.4";

    src = fetchFromGitHub {
      owner = "kavishdevar";
      repo = "librepods";
      rev = "v${version}";
      hash = "sha256-R84mSviNoDAh5uQhUKBnsOf850E8fCHvDlWKWCBtZF4=";
    };

    sourceRoot = "source/linux";

    nativeBuildInputs = with pkgs; [
      cmake
      pkg-config
      qt6.wrapQtAppsHook
    ];

    buildInputs = with pkgs; [
      qt6.qtbase
      qt6.qtconnectivity
      qt6.qtdeclarative
      qt6.qttools
      openssl
      libpulseaudio
    ];

    meta = with lib; {
      description = "Open-source AirPods client for Linux";
      homepage = "https://github.com/kavishdevar/librepods";
      license = licenses.gpl3Only;
      platforms = platforms.linux;
      mainProgram = "librepods";
    };
  }
