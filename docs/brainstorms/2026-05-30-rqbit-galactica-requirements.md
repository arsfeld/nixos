---
date: 2026-05-30
topic: rqbit-galactica
---

# rqbit on galactica — requirements

## Summary

Add a standalone [rqbit](https://github.com/ikatson/rqbit) instance to galactica for
ad-hoc, hands-on torrenting via its web UI. It runs confined to the existing AirVPN
WireGuard namespace (alongside qBittorrent and Transmission) so no home IP leaks to the
swarm, is declared through `mkService`, and is reachable at `rqbit.arsfeld.one`. It is
deliberately *not* wired into the Sonarr/Radarr pipeline — this is a try-it-out instance.

## Key Decisions

- **VPN-confined, not bare.** rqbit joins the same AirVPN WireGuard namespace
  (`vpnNamespace = "wg"`) used by `qbittorrent-vpn.nix` and `transmission-vpn.nix`. The
  user explicitly chose this over a bare host-network instance: a torrent client on the
  host network would expose galactica's home IP to every swarm it joins, and confinement
  is the established galactica pattern.
- **Front with Authelia, do not bypass auth.** rqbit's web UI and HTTP API have no
  built-in authentication. Unlike qBittorrent/Transmission (which set `bypassAuth = true`
  because they're effectively only reachable inside the VPN/Tailscale), the
  `rqbit.arsfeld.one` vhost should sit behind Authelia so the public Cloudflare hostname
  is not an open torrent controller.
- **Standalone, no *arr integration.** Declared as its own service with no download-client
  registration in Sonarr/Radarr. Role is exploratory; promoting it to a pipeline client is
  a separate, later decision.

## Requirements

- R1. rqbit runs on galactica, confined to the AirVPN WireGuard namespace used by the
  existing torrent clients, with the same DNS-leak / kill-switch protection those clients
  rely on.
- R2. rqbit is declared via the `mkService` helper (per repo convention), not by writing to
  `virtualisation.oci-containers` or `media.gateway.services` directly.
- R3. The web UI is reachable at `rqbit.arsfeld.one`, routed through the existing gateway /
  cloudflared path.
- R4. The `rqbit.arsfeld.one` vhost requires Authelia authentication (auth is **not**
  bypassed).
- R5. Completed downloads land in a dedicated directory under the storage volume, distinct
  from the `radarr` / `sonarr` download subfolders, so the try-it-out instance doesn't
  collide with the automated pipeline.
- R6. rqbit is not registered as a download client in Sonarr or Radarr.

## Scope Boundaries

- Sonarr/Radarr download-client integration — out of scope; revisit only if rqbit graduates
  from try-it-out to a real pipeline client.
- Replacing or removing qBittorrent or Transmission — out of scope; rqbit is additive.
- rqbit's streaming / play-while-downloading features as a deliberate workflow — not a goal
  here; available to poke at, but nothing is built around them.

## Dependencies / Assumptions

- rqbit is available in nixpkgs (verified: `nixpkgs#rqbit` is v8.1.1) and ships an official
  container image (`ikatson/rqbit`). Whether to run the native package or the container is a
  planning decision, deferred to `ce-plan`.
- Reaching a service inside the WireGuard namespace from the gateway uses the same
  namespace-IP `host` override pattern already used by `qbittorrent-vpn.nix` /
  `transmission-vpn.nix` — assumed reusable as-is.
