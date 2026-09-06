# iroh relay (cae1-1.relay.mydia.dev)

Mydia's p2p relay. Clients are compiled with this hostname as their default
(`lib/mydia/p2p/server.ex` and `player/lib/core/p2p/p2p_service.dart` in the
mydia repo), overridable per install with `IROH_RELAY_URL` and per player build
with `--dart-define=IROH_RELAY_URL`. Losing this host takes remote access down
for every install that has not set an override.

Moved here from the can-1 k3s cluster on 2026-09-06, because metadata-relay is
moving to Cloudflare Workers and the relay was the last mydia service keeping
that VPS in the picture. That Worker migration has not cut over yet: at the time
of writing `relay.mydia.dev` is still served by the Elixir relay on can-1, so
can-1 is not yet safe to retire.

## Shape

- Public: TCP 443 through Caddy, UDP 7842 direct for QUIC address discovery.
- Loopback: 8443 relay HTTPS, 8480 relay HTTP (captive portal only), 9090
  metrics.
- Certificate: `security.acme` DNS-01 via Cloudflare, SAN-covering
  `cae1-2.relay.mydia.dev`, mounted read-only into the container at `/certs`
  from `/var/lib/acme/cae1-1.relay.mydia.dev`.

The DNS-01 provider is invisible in `iroh-relay.nix`: that module only sets
`extraDomainNames` and `reloadServices` on `security.acme.certs`. DNS-01 works
at all because `hosts/basestar/configuration.nix` sets `media.config.enable =
true`, which pulls in `modules/media/config.nix`'s host-wide
`security.acme.defaults`, carrying `dnsProvider = "cloudflare"` and the API
token `environmentFile`. That token must be scoped to write `_acme-challenge`
TXT records in the **mydia.dev** zone, a different zone from the personal
`arsfeld.dev` and `arsfeld.one` ones it was provisioned for. Get the scope
wrong and `acme-cae1-1.relay.mydia.dev.service` fails, the container never
gets a certificate, and it crash-loops on first deploy. That fails loudly, but
it is a hard first-deploy blocker.

iroh 1.0 has no STUN. The UDP 3478 port the k8s deployment published was
vestigial and is not carried over.

## Four things that will bite

**The version pin.** `v1.0.0` is held back deliberately. The published v1.0.3
image is a static musl build carrying noq-udp 1.1.0, which panics on the first
received datagram (n0-computer/noq#774: musl declares `cmsghdr` with align 4
while the `SCM_TIMESTAMPNS` path decodes a `timespec` with align 8, and
`SO_TIMESTAMPNS` is set unconditionally on Linux). Rolling it out on 2026-08-19
put the relay into CrashLoopBackOff. Only iroh 1.0.3 took noq 1.1.0; 1.0.1 and
1.0.2 are on noq 1.0.x. Run `./iroh-relay-verify-image.sh <image>` before
changing the pin. A boot test cannot catch this: the panic needs real UDP
traffic.

`nixpkgs#iroh-relay` is packaged at 1.0.3 as a glibc build, which is not
affected. Switching to a native NixOS service rather than the container is the
obvious way out of the pin, and is untried.

**The config keys.** `https_bind_addr` and `quic_bind_addr` live inside `[tls]`,
and metrics is `metrics_bind_addr`. The relay's `Config` and `TlsConfig` do not
set `deny_unknown_fields`, so misplacing any of them is silent. The k8s
ConfigMap this replaced had all three wrong and worked anyway, because the
defaults it fell back to happened to match. They do not match here. The one
check that catches it is `ss -ulnp | grep 7842` showing `0.0.0.0`, not
`127.0.0.1`; QUIC address discovery dies silently otherwise.

**The OCI security list.** UDP 7842 needs an ingress rule in the Oracle Cloud
VCN security list as well as `networking.firewall.allowedUDPPorts`. The OCI rule
is invisible from inside the instance: the socket binds, the service looks
healthy, and no packet arrives.

**The Cloudflare records must stay grey cloud.** `cae1-1.relay.mydia.dev` and
`cae1-2.relay.mydia.dev` are DNS-only records and must never be switched to
proxied. Proxying terminates TLS at Cloudflare, so the relay's own certificate
is never used, UDP 7842 never arrives at all, and QUIC address discovery reports
a Cloudflare address instead of the client's. Orange cloud is the dashboard
default when creating a record, so this is easy to do by accident and the
symptom (relay reachable over HTTPS, hole punching quietly worse) does not point
at the cause.

## Verifying

```bash
ss -ulnp | grep 7842                                    # must be 0.0.0.0
curl -sI https://cae1-1.relay.mydia.dev/generate_204     # 204
curl -s http://127.0.0.1:9090/metrics | grep relayserver_accepts_total
```

The Gatus check this plan adds exercises only the HTTPS path through Caddy,
and Gatus has no UDP or QUIC primitive. It cannot see the OCI security-list
gap or a Cloudflare record drifting to proxied, the two traps above that leave
HTTPS perfectly healthy while UDP 7842 is dead. `ss -ulnp | grep 7842` and a
real client hole-punch test remain the only way to catch those; a green
dashboard is not evidence that address discovery works.

`relayserver_unique_client_keys_total` is useless on this version: upstream
builds `ClientCounter::default()` per connection actor, so it exactly equals
accepts. `relayserver_bytes_sent_total` reads 0 even with live connections, also on this
version. Use `accepts - disconnects` for currently connected nodes.

The only test that means anything is a real client relaying real traffic. Point
a dev mydia at the relay with `IROH_RELAY_URL` and stream something.
