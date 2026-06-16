# Resilience for cloudflared tunnels (generic across hosts and tunnel UUIDs).
#
# cloudflared resolves Cloudflare's edge SRV records (_v2-origintunneld._tcp.
# argotunnel.com) via the system resolver. On our hosts that resolver is
# Tailscale MagicDNS (100.100.100.100), which may not be answering yet at boot.
# The upstream module orders the unit only on network-online.target — not on
# Tailscale being up — so edge discovery fails a few times in quick succession,
# trips systemd's default start-limit (5 failures / 10s), and the unit gives up
# for good. The tunnel then stays down until a manual restart, and every
# tunneled service returns Cloudflare error 530.
#
# Fix, applied to every configured tunnel so it survives the UUID changing:
#   - order after tailscaled so MagicDNS is up before the first attempt
#   - StartLimitIntervalSec = 0 so it retries forever instead of giving up
# Restart = "on-failure" (set upstream) is left intact; combined with the
# disabled start-limit it means the tunnel reconnects on its own.
{
  config,
  lib,
  ...
}: let
  cfg = config.services.cloudflared;
in {
  config = lib.mkIf cfg.enable {
    systemd.services =
      lib.mapAttrs'
      (name: _:
        lib.nameValuePair "cloudflared-tunnel-${name}" {
          after = ["tailscaled.service"];
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig.RestartSec = "10s";
        })
      cfg.tunnels;
  };
}
