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

            # nixpkgs' fprintd (1.94.5) requires libfprint-2 >= 1.94.9 via
            # pkg-config; this fork's meson.build still reports 1.94.1 (its last
            # upstream sync in 2021). The version string is just a build-time
            # dependency-check label here, so bump the label to match the one real
            # public-API change between those tags (see below) rather than the
            # fork's actual age.
            substituteInPlace meson.build \
              --replace-fail \
                "version: '1.94.1'," \
                "version: '1.94.9',"

            # fprintd 1.94.5's device.c references FP_DEVICE_RETRY_TOO_FAST, added
            # upstream in 1.94.9 (NEWS: "fp-device: Add FP_DEVICE_RETRY_TOO_FAST
            # retry error") -- the only public FpDevice/FpPrint API addition between
            # 1.94.1 and 1.94.9; every other change in that range is new
            # driver/PID support or internal-only fixes. Add the enum value so
            # fprintd's switch over FpDeviceRetry compiles; goodixtls52xd never
            # emits it, so this is purely a missing-symbol fix, not new behavior.
            substituteInPlace libfprint/fp-device.h \
              --replace-fail \
                'FP_DEVICE_RETRY_REMOVE_FINGER,
      } FpDeviceRetry;' \
                'FP_DEVICE_RETRY_REMOVE_FINGER,
        FP_DEVICE_RETRY_TOO_FAST,
      } FpDeviceRetry;'
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
