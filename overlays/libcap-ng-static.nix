# pkgsStatic.libcap_ng checkPhase fails against musl: the test stubs for
# fgetxattr/fsetxattr collide with musl's libc definitions
# (stevegrubb/libcap-ng#85). That package sits under qemu-user-static, which
# raider pulls in via boot.binfmt.preferStaticEmulators.
#
# Mirror the upstream interim fix (NixOS/nixpkgs#562812). Drop this overlay
# once that PR lands in our nixpkgs pin.
final: prev: {
  libcap_ng = prev.libcap_ng.overrideAttrs (_old: {
    doCheck = !prev.stdenv.hostPlatform.isStatic;
  });
}
