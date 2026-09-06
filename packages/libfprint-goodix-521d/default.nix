{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub;
in
  stdenv.mkDerivation {
    pname = "libfprint-goodix-521d";
    version = "1.94.100-unstable-2026-09-05";

    # Upstream libfprint v1.94.100 with the community goodixtls drivers ported
    # on top, plus the firmware-gate widening this sensor needs. Rebased from
    # infinytum/libfprint@5e14af7f, which was pinned to v1.94.1 (2021).
    #
    # The gate is a prefix match on "GFUSB_GM168SEC_APP_" rather than upstream's
    # strcmp against a single hardcoded 10019 literal, so this builds works
    # against both 10019 and 10034 with no further patching. That matters
    # because booting Windows and enrolling in Windows Hello reverts the sensor
    # to 10034 and re-keys it, and the sensor is currently kept on 10034 on
    # purpose -- see extract-firmware.py in this directory, which recovers a
    # flashable 10034 image from the Windows driver, and Task 9 of
    # docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md.
    src = fetchFromGitHub {
      owner = "arsfeld";
      repo = "libfprint-goodixtls";
      rev = "6c078afeabca6e35eab6cc4e9beee24d8078e772";
      hash = "sha256-mtF5EW4eRuvCH/06EsHbv5RjfxJ74w9DG3gaJWkRcYM=";
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
      homepage = "https://github.com/arsfeld/libfprint-goodixtls";
      license = licenses.lgpl21Plus;
      platforms = platforms.linux;
    };
  }
