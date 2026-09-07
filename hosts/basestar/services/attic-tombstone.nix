# Tombstone for the retired attic binary cache.
#
# attic was retired on 2026-09-07 and all five of its DNS records deleted. That
# did not make the hostname stop answering: the zone has a proxied
# `*.arsfeld.dev` wildcard CNAME, so `attic.arsfeld.dev` still resolves, still
# reaches this host, and — with no vhost claiming it — landed on Caddy's default
# response, which is HTTP 200 with a zero-byte body, for every path.
#
# That is strictly worse than the endpoint being gone. Nix parses an empty
# `nix-cache-info` without complaint, so it initialises the substituter and
# never disables it; every subsequent narinfo lookup then fails with
#
#   error: NAR info file '<hash>.narinfo' is corrupt: StorePath missing
#
# instead of missing cleanly and falling through to a local build. Reproduced on
# pegasus before this vhost existed.
#
# Any host still carrying the old substituter list hits this, and five of the
# nine (router, r2s, raspi3, blackbird, octopi) were unreachable when attic was
# retired, so they keep it until their next deploy.
#
# A non-200 restores fail-safe behaviour: nix gives up on an unusable
# substituter at store-open time and carries on. 410 rather than 404 because the
# resource is deliberately and permanently gone.
#
# Safe to delete once all nine hosts have been deployed past 19686a2 ("drop the
# attic substituter and its signing key"). Until then it is load-bearing for the
# stale ones.
{
  services.caddy.virtualHosts."attic.arsfeld.dev" = {
    useACMEHost = "arsfeld.dev";
    extraConfig = ''
      respond "attic was retired on 2026-09-07; the cache is https://cache.arsfeld.dev" 410
    '';
  };
}
