final: prev:
# Only override openldap on i686-linux. The 32-bit build pulled in by lutris's
# multilib FHS env has no cache hit on cache.nixos.org, so Nix must build it
# locally, where test017-syncreplication-refresh fails (flaky under high CPU
# concurrency). Skipping the test phase lets the build complete.
#
# Leaving x86_64-linux openldap untouched keeps the cached output, which means
# wine and everything else that links openldap stay substitutable.
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isi686 {
  openldap = prev.openldap.overrideAttrs (_: {
    doCheck = false;
  });
}
