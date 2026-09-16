# Home Assistant: Hilo and Eufy Security

Date: 2026-09-16. Host: galactica (the only host with `constellation.home-assistant.enable`).

## Goal

Make two integrations usable in galactica's Home Assistant (2026.5.4, nixpkgs 26.05):

- **Hilo** — Hydro-Québec's demand-response platform (`dvd-dev/hilo`).
- **Eufy Security** — cameras, doorbell, lock, HomeBase.

## Starting state

- `/var/lib/hass/custom_components/hilo` is a HACS install of hilo 2025.12.4 from 2025-12-14.
  It has never worked: the NixOS module runs Home Assistant with pip disabled
  ("Skipping pip installation of required modules"), so its one requirement, `python-hilo`, was
  never installed, and no `hilo` config entry exists.
- Neither `python-hilo` nor a Hilo or Eufy Security component is in nixpkgs (stable or unstable).
  Every dependency of `python-hilo` 2026.9.1 is.
- The Eufy Security stack everyone used — `fuatakgun/eufy_security` plus `bropat/eufy-security-ws` —
  was archived on 2026-09-12. Both point at mega-yfue's rewrite: `ha-eufy-sdk` (the integration,
  domain `eufy_sdk`) and `ha-eufy-sdk-bridge` (a Node daemon with go2rtc bundled, shipped as
  `ghcr.io/mega-yfue/ha-eufy-sdk-bridge`).

## Design

### Hilo

- `python-hilo` 2026.9.1 goes into `overlays/python-packages.nix`, built from PyPI. Being a
  `pythonPackagesExtensions` entry, it lands in Home Assistant's own python package set too.
- `packages/home-assistant-hilo` builds `hilo` 2026.9.5 with `buildHomeAssistantComponent`, and the
  module adds it to `customComponents`. hilo's `hacs.json` minimum is HA 2025.8.0.
- Nix pins both, so hilo and the library it requires move together. Leaving hilo under HACS was
  rejected: HACS would update it independently, and any release raising its `python-hilo` floor
  would break silently under the pip-less runtime.
- **One-time manual step before the first deploy:** delete the HACS directory
  `/var/lib/hass/custom_components/hilo`. The module's pre-start runs
  `ln -fns <store path> /var/lib/hass/custom_components/`; with a real directory of the same name
  already there, the link is created *inside* it and HA keeps loading the stale copy.

### Eufy Security

- **Bridge:** `media.services.eufy-sdk-bridge` on galactica, image
  `ghcr.io/mega-yfue/ha-eufy-sdk-bridge:0.2.0`.
  - The bridge's WebSocket has no authentication, so it gets no gateway entry, no
    `tailscaleExposed`, and `port = null`. It publishes `127.0.0.1:3000` (WS control, snapshots)
    and `127.0.0.1:8554` (go2rtc RTSP — the integration hard-codes this port for `stream_source`)
    on loopback only. Home Assistant is a native service on the same host, so loopback reaches both.
  - `configDir = "/app/data"` persists the Eufy session token, so restarts do not re-trigger 2FA.
  - Credentials live in the sops secret `eufy-sdk-bridge-env` (`EUFY_EMAIL`, `EUFY_PASSWORD`) and
    belong to a **secondary** Eufy account shared from the main one with admin rights. Eufy allows
    one session per account, so the bridge on the main account would be kicked by the phone app.
  - `EUFY_COUNTRY = "CA"`.
  - No host networking (repo convention), so go2rtc's WebRTC port (8555/udp) is not wired. Live
    video goes through HA's `stream` component from RTSP instead.
- **Integration:** `packages/home-assistant-eufy-sdk` builds `eufy_sdk` 0.2.1 with
  `buildHomeAssistantComponent`; it has no Python requirements.
- **Versions are pinned, not watched.** The bridge image and the integration are upgraded together in
  one commit. The project is five weeks old, and `:latest` plus `watchImage` would let the bridge
  drift ahead of the integration.
- **HA version:** `ha-eufy-sdk`'s `hacs.json` asks for HA 2026.6.4; galactica runs 2026.5.4. The
  number was set by the project's first commit, from the integration template's dev pin, not in
  response to an API it uses. Implementation starts by importing every `eufy_sdk` module against
  galactica's HA. If that fails, the fallback is HA from nixpkgs-unstable on galactica, which is a
  separate decision.

### After deploy (UI)

1. Settings → Devices & Services → Add Integration → **Hilo**, log in to the Hilo account.
2. Add Integration → **eufy-sdk**, host `127.0.0.1`, port `3000`, complete 2FA/captcha in the flow.

## Out of scope

- The two declarative Hilo automations in `modules/constellation/home-assistant.nix` reference
  placeholder entities (`binary_sensor.hilo_challenge`, `climate.tuya_heat_pump`). Fix them once
  the real entity ids exist.
- WebRTC for Eufy cameras.

## Verification

- `nix build` of galactica's toplevel.
- After deploy: `home-assistant` and `podman-eufy-sdk-bridge` active; `curl 127.0.0.1:3000/healthz`
  answers; the bridge ports are bound to `127.0.0.1` only; the HA log shows hilo and eufy_sdk
  loading without import errors; both integrations appear in the Add Integration list.
