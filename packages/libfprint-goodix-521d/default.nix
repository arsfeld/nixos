{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub;
in
  stdenv.mkDerivation {
    pname = "libfprint-goodix-521d";
    version = "1.94.1-unstable-2021-11-17";

    src = fetchFromGitHub {
      owner = "infinytum";
      repo = "libfprint";
      rev = "5e14af7f136265383ca27756455f00954eef5db1";
      hash = "sha256-MFhPsTF0oLUMJ9BIRZnSHj9VRwtHJxvWv0WT5zz7vDY=";
    };

    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
    ];

    buildInputs = with pkgs; [
      glib
      libgudev
      gusb
      nss
      openssl
      pixman
      systemdLibs
    ];

    # The fork is from 2021 and does not compile clean against modern GCC.
    # The AUR package libfprint-goodix-521d applies the same relaxation.
    env.NIX_CFLAGS_COMPILE = "-Wno-incompatible-pointer-types";

    # Widen the firmware gate. Upstream hard-compares against 10019; Windows
    # ships 10034. A prefix match keeps future firmware revisions working
    # without another patch.
    postPatch = ''
      substituteInPlace libfprint/drivers/goodixtls/goodix52xd.c \
        --replace-fail \
          'if (strcmp(firmware, GOODIX_52XD_FIRMWARE_VERSION)) {' \
          'if (strncmp(firmware, "GFUSB_GM168SEC_APP_", 19)) {'
    '';

    mesonFlags = [
      # Build only our driver. The fork carries 2021-era drivers that are not
      # worth compiling against a modern toolchain.
      "-Ddrivers=goodixtls52xd"
      "-Dintrospection=false"
      "-Ddoc=false"
      "-Dgtk-examples=false"
      "-Dudev_rules_dir=${placeholder "out"}/lib/udev/rules.d"
      "-Dudev_hwdb_dir=${placeholder "out"}/lib/udev/hwdb.d"
    ];

    meta = with lib; {
      description = "libfprint fork with the goodixtls driver for Goodix 27c6:521d";
      homepage = "https://github.com/infinytum/libfprint";
      license = licenses.lgpl21Plus;
      platforms = platforms.linux;
    };
  }
