# Task: Deploy Bazaar to Raider Host

**IMPORTANT**: Only a 100% building and working Bazaar application is an acceptable outcome. Partial solutions or workarounds that skip Bazaar are not acceptable.

## Problem
The deployment of the `raider` host fails because the Bazaar package (located in `packages/bazaar/`) has an unresolved dependency on `glycin`, which is referenced but doesn't exist in the repository.

## Error Details
```
error: path '/nix/store/94karyp5jqfgljxkj618k17kkxzzxb4p-source/packages/glycin' does not exist
```

## Root Cause
In `packages/bazaar/default.nix`, line 31 references:
```nix
glycin = pkgs.callPackage ../glycin {};
```

However, the `packages/glycin/` directory doesn't exist in the repository.

## Solution Steps

### 1. Create the Glycin Package
Glycin is a GNOME library for image loading that's not yet in nixpkgs. You need to create `packages/glycin/default.nix` with the following structure:

```nix
{
  lib,
  stdenv,
  fetchFromGitLab,
  meson,
  ninja,
  pkg-config,
  gtk4,
  libadwaita,
  glib,
  gobject-introspection,
  vala,
  libheif,
  libjxl,
  librsvg,
  webp-pixbuf-loader,
  ...
}:

stdenv.mkDerivation rec {
  pname = "glycin";
  version = "1.1.1";  # Check for latest version

  src = fetchFromGitLab {
    domain = "gitlab.gnome.org";
    owner = "sophie-h";
    repo = "glycin";
    rev = version;
    hash = "sha256-XXXXX";  # You'll need to determine this
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    gobject-introspection
    vala
  ];

  buildInputs = [
    gtk4
    libadwaita
    glib
    libheif
    libjxl
    librsvg
    webp-pixbuf-loader
  ];

  meta = with lib; {
    description = "Sandboxed image loading for GNOME";
    homepage = "https://gitlab.gnome.org/sophie-h/glycin";
    license = licenses.lgpl21Plus;
    platforms = platforms.linux;
  };
}
```

### 2. Determine the Correct Hash
After creating the initial glycin package:
1. Run `nix build .#bazaar` to get the expected hash
2. Update the hash in the glycin package

### 3. Handle Additional Dependencies
Glycin may require additional dependencies like:
- `glycin-loaders` (separate package for image format loaders)
- Various image format libraries (libheif, libjxl, etc.)

### 4. Test the Build
```bash
# Test building Bazaar locally first
nix build .#bazaar

# If successful, deploy to raider
just deploy raider
```

## Additional Notes
- Glycin is a relatively new library (2024) for sandboxed image loading in GNOME
- It's designed to work with libadwaita and GTK4 applications
- The library provides secure image loading by running decoders in sandboxed processes
- Upstream: https://gitlab.gnome.org/sophie-h/glycin

## Verification
Once implemented, verify with:
```bash
# Build test
nix build .#bazaar --show-trace

# Full deployment test
just deploy raider
```

## References
- Bazaar GitHub: https://github.com/kolunmi/bazaar
- Glycin GitLab: https://gitlab.gnome.org/sophie-h/glycin
- Similar nixpkgs PR discussions for new GNOME libraries