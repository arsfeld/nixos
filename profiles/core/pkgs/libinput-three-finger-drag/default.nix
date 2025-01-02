{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  makeBinaryWrapper,
  cosmic-icons,
  just,
  pkg-config,
  glib,
  libxkbcommon,
  wayland,
  xorg,
}:
rustPlatform.buildRustPackage rec {
  pname = "libinput-three-finger-drag";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "marsqing";
    repo = "libinput-three-finger-drag";
    rev = "6acd3f84b551b855b5f21b08db55e95dae3305c5";
    hash = "";
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
    allowBuiltinFetchGit = true;
  };

  nativeBuildInputs = [just pkg-config makeBinaryWrapper];
  buildInputs = [glib libxkbcommon wayland];

  meta = with lib; {
    homepage = "https://github.com/marsqing/libinput-three-finger-drag";
    description = "Three-finger-drag support for libinput";
    license = licenses.mit;
    #maintainers = with maintainers; [ahoneybun nyabinary];
    platforms = platforms.linux;
  };
}
