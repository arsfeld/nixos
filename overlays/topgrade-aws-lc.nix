# nixpkgs' cargoUseSystemLibs hook exports AWS_LC_SYS_USE_SYSTEM=1 for every
# Rust package, but topgrade 17.15.0 pulls aws-lc-sys 0.47 without adding
# aws-lc to its buildInputs, so aws-lc-sys panics instead of falling back to
# its bundled build:
#
#   AWS_LC_SYS_USE_SYSTEM=1 requires a system-installed AWS-LC, but none was
#   found.
#
# Opt this package out of the hook and supply cmake for the bundled build.
# Delete once nixpkgs' topgrade adds aws-lc/pkg-config (or drops aws-lc-sys).
final: prev: {
  topgrade =
    if prev.lib.versionAtLeast prev.topgrade.version "17.15.0"
    then
      prev.topgrade.overrideAttrs (old: {
        dontCargoUseSystemLibs = true;
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [prev.cmake];
      })
    else prev.topgrade;
}
