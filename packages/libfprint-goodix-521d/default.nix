{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub;
in
  stdenv.mkDerivation {
    pname = "libfprint-goodix-521d";
    version = "1.94.100-unstable-2026-09-05";

    # Upstream libfprint v1.94.100 with the community goodixtls drivers ported
    # on top, plus the firmware-gate widening this sensor needs. Rebased from
    # infinytum/libfprint@5e14af7f, which was pinned to v1.94.1 (2021).
    src = fetchFromGitHub {
      owner = "arsfeld";
      repo = "libfprint";
      rev = "5fa6c73300e661b3b52bd9b37283133c49976b9c";
      hash = "sha256-/wVbWc83M7oVp6sVEzD37UxMneCZQDuWQVxmp4V4q/g=";
    };

    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
      python3
    ];

    buildInputs = with pkgs; [
      cairo
      glib
      libgudev
      gusb
      openssl
      pixman
      systemdLibs
    ];

    mesonFlags = [
      # Build only our driver. The fork carries sibling goodixtls drivers
      # (511, 53xd) that no host here has hardware for.
      "-Ddrivers=goodixtls52xd"
      "-Dintrospection=false"
      "-Ddoc=false"
      "-Dgtk-examples=false"
      "-Dudev_rules_dir=${placeholder "out"}/lib/udev/rules.d"
      "-Dudev_hwdb_dir=${placeholder "out"}/lib/udev/hwdb.d"
    ];

    meta = with lib; {
      description = "libfprint fork with the goodixtls driver for Goodix 27c6:521d";
      homepage = "https://github.com/arsfeld/libfprint";
      license = licenses.lgpl21Plus;
      platforms = platforms.linux;
    };
  }
