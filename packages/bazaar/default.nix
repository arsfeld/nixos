{pkgs, ...}: let
  inherit (pkgs) lib stdenv fetchFromGitHub fetchFromGitLab fetchurl python3 rustPlatform;

  # Build glycin since it's not in nixpkgs yet
  glycin = stdenv.mkDerivation rec {
    pname = "glycin";
    version = "1.2.1";

    src = fetchFromGitLab {
      domain = "gitlab.gnome.org";
      owner = "GNOME";
      repo = "glycin";
      rev = version;
      hash = "sha256-M4DcWLE40OPB7zIkv4uLj6xTac3LTDcZ2uAO2S/cUz4=";
    };

    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit src;
      name = "${pname}-${version}";
      hash = "sha256-iNSpLvIi3oZKSRlkwkDJp5i8MdixRvmWIOCzbFHIdHw=";
    };

    nativeBuildInputs = with pkgs;
      [
        meson
        ninja
        pkg-config
        gobject-introspection
        vala
        cargo
        rustc
        rust-bindgen
        python3
        wrapGAppsHook4
        gi-docgen
      ]
      ++ (with rustPlatform; [
        cargoSetupHook
      ]);

    buildInputs = with pkgs; [
      gtk4
      libadwaita
      glib
      libheif
      libjxl
      librsvg
      lcms2
      bubblewrap
    ];

    propagatedBuildInputs = with pkgs; [
      libseccomp # Required by glycin-1.pc
      lcms2 # Required by glycin-1.pc
    ];

    mesonFlags = [
      "-Dprofile=release"
      "-Dglycin-loaders=true"
    ];

    meta = with lib; {
      description = "Sandboxed and extendable image loading for GNOME";
      homepage = "https://gitlab.gnome.org/sophie-h/glycin";
      license = licenses.mpl20;
      platforms = platforms.linux;
    };
  };

  # Build blueprint-compiler 0.18.0 since bazaar needs >= 0.18.0
  blueprint-compiler-new = python3.pkgs.buildPythonApplication rec {
    pname = "blueprint-compiler";
    version = "0.18.0";

    src = fetchurl {
      url = "https://gitlab.gnome.org/jwestman/blueprint-compiler/-/archive/v${version}/blueprint-compiler-v${version}.tar.gz";
      hash = "sha256-cDx8zSPLb3eo/pyMrg+R3pJ0kQypU953E1tuedv/H8M=";
    };

    format = "other";

    nativeBuildInputs = with pkgs; [
      meson
      ninja
    ];

    propagatedBuildInputs = with python3.pkgs; [
      pygobject3
    ];

    doCheck = false;

    postPatch = ''
      patchShebangs docs/collect-sections.py
    '';
  };

  # Build libdex 0.11.1 since bazaar needs >= 0.11.1
  libdex = stdenv.mkDerivation rec {
    pname = "libdex";
    version = "0.11.1";

    src = fetchFromGitHub {
      owner = "GNOME";
      repo = "libdex";
      rev = version;
      hash = "sha256-0HYsoF/WhMNyLzuHoDC4z04ZmGo4a62RYVy7nechJtg=";
    };

    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
      vala
      gobject-introspection
    ];

    buildInputs = with pkgs; [
      glib
      sysprof
      liburing
    ];

    mesonFlags = [
      "-Ddocs=false"
      "-Dexamples=false"
      "-Dtests=false"
    ];
  };
in
  stdenv.mkDerivation rec {
    pname = "bazaar";
    version = "0.3.0";

    src = fetchFromGitHub {
      owner = "kolunmi";
      repo = "bazaar";
      rev = "v${version}";
      hash = "sha256-etP11EbFnTs1/GECSzrExu6uLmiiBxcLF8MjTP+or3c=";
    };

    nativeBuildInputs = with pkgs;
      [
        meson
        ninja
        pkg-config
        wrapGAppsHook4
        desktop-file-utils
        gettext
        gobject-introspection
        vala
      ]
      ++ [
        blueprint-compiler-new # Use our newer version
      ];

    buildInputs = with pkgs;
      [
        gtk4
        libadwaita
        flatpak
        appstream
        libxml2
        libxmlb
        libyaml
        libsoup_3
        json-glib
        glib
      ]
      ++ [
        libdex # Our custom libdex 0.11.1
        glycin # Our custom glycin
      ];

    mesonFlags = [
      # No special flags needed
    ];

    meta = with lib; {
      description = "A new app store for GNOME";
      homepage = "https://github.com/kolunmi/bazaar";
      license = licenses.gpl3Only;
      maintainers = with maintainers; [];
      platforms = platforms.linux;
      mainProgram = "bazaar";
    };
  }
