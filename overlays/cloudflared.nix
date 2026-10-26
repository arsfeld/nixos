# cloudflared < 2026.10.2 trusts third-party certificates Cloudflare announced
# as compromised (Cloudflare blog, 2026-10-20), and Cloudflare asked every
# tunnel operator to upgrade. galactica and pegasus each run a tunnel. nixpkgs
# ships 2026.5.2 here and only 2026.10.1 on master, so bump the source. Two
# things changed upstream since the nixpkgs version: the in-tree vendor/
# directory is gone (so vendorHash is no longer null), and go.mod needs
# go >= 1.27.3, which nixpkgs has as go_1_27 without a buildGo127Module.
# Delete once nixpkgs has cloudflared >= 2026.10.2.
final: prev: {
  cloudflared =
    if prev.lib.versionOlder prev.cloudflared.version "2026.10.2"
    then
      (prev.cloudflared.override {
        buildGoModule = prev.buildGoModule.override {go = prev.go_1_27;};
      }).overrideAttrs (finalAttrs: old: {
        version = "2026.10.4";
        src = prev.fetchFromGitHub {
          owner = "cloudflare";
          repo = "cloudflared";
          tag = finalAttrs.version;
          hash = "sha256-HuKjytbGutwjUMepozeUmeeHczm4qI7vMvS+hgLsaZ0=";
        };
        vendorHash = "sha256-WtGk5HE6PxAWqwvj8mAAzobuoSw+y6BqBEEB0hRQafk=";
        # nixpkgs' preCheck renames sandbox-hostile tests with substituteInPlace
        # on files that have since moved, which fails the build. Skip the same
        # tests by name instead (reasons are in the nixpkgs package).
        preCheck = ''
          export HOME="$(mktemp -d)"
        '';
        checkFlags = [
          "-skip=^(${prev.lib.concatStringsSep "|" [
            "TestProtocolPercentage"
            "TestICMPRouterEcho"
            "TestConcurrentRequestsToSameDst"
            "TestICMPRouterRejectNotEcho"
            "TestTraceICMPRouterEcho"
            "TestFunnelIdleTimeout"
            "TestReuseFunnel"
            "TestManagerCtxDoneCloseSessions"
            "TestSupportedCurvesNegotiation"
          ]})$"
        ];
      })
    else prev.cloudflared;
}
