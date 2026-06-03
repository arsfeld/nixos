# firefoxpwa (2.18.2) fails to build with nixpkgs unstable: the Firefox wrapper
# now disables update checks by `touch "$out/lib/firefoxpwa/is-packaged-app"`
# (introduced in nixpkgs 1da3ca73732263dc0473f0d64ccdfa810eaa1fac), but the
# unwrapped package never creates that directory, so the wrap step dies with:
#   touch: cannot touch '.../lib/firefoxpwa/is-packaged-app': No such file or directory
#
# Mirror the upstream fix (NixOS/nixpkgs#525720) by creating the empty directory
# in the unwrapped package's postInstall. Drop this overlay once that PR lands in
# our nixpkgs pin.
final: prev: {
  firefoxpwa-unwrapped = prev.firefoxpwa-unwrapped.overrideAttrs (old: {
    postInstall =
      (old.postInstall or "")
      + ''
        mkdir -p $out/lib/firefoxpwa
      '';
  });
}
