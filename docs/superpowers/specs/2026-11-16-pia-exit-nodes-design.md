# PIA exit nodes on galactica, driven from Home Assistant

Date: 2026-11-16. Status: design.

## Goal

A whole device (blackbird, a Mac, a phone) sends its internet traffic out of a chosen
country through Private Internet Access while keeping full tailnet access, switched with
Tailscale's own exit-node picker. No new client software and no per-device configuration.

Which countries are offered is decided in **Home Assistant**, not in nix: galactica has a
fixed number of exit **slots** (2), and each slot has a dropdown in HA listing every PIA
region plus Off. HA also shows, per slot, whether it is actually working and where its
traffic leaves from. The first use is Brazil (`br-so`, for Brazilian streaming services).

The slot count is the hard cap on extra PIA connections: at most 1 (Transmission) + 2.

## Background

`quiet-crafts/unbraid-mac` was the prompt. It is a macOS app wrapping sing-box in a
packet-tunnel extension: per-app rules on the process path pick a route, each route is a
WireGuard/OpenVPN endpoint, and Tailscale runs as sing-box's embedded endpoint so tailnet
traffic and several VPN exits share one TUN. Its PIA support is the same flow as
`pia-foss/manual-connections` (token, server list v6, `addKey` on `:1337` with the pinned
CA), which `packages/pia` already implements. Nothing in it runs on Linux; what we want is
whole-device, not per-app, and Tailscale exit nodes already give exactly that: with an exit
node selected, internet traffic leaves through it while tailnet traffic still goes to
peers directly, and "allow local network access" keeps the LAN.

## Non-goals

- Per-app routing, or anything installed on clients. The only UI is Home Assistant's.
- More simultaneous countries than slots. Raising the cap is a one-number nix change.
- Port forwarding on exits. Only Transmission's existing `pia` namespace forwards a port.
- Alerts when a slot goes down. The entities make one a UI automation away.

## Design

### Shape

```
client (exit node = pia-br-so) ──tailnet──▶ tailscaled-piax1  [galactica, netns `piax1`]
                                               │ userspace networking: forwarded flows are sockets
                                               ▼
                                            wg (PIA region chosen in HA) ──▶ internet

HA select "PIA exit 1" ──REST──▶ pia-exits.service (127.0.0.1:8592)
                                   writes slot 1's region, restarts pia-exit-1.target,
                                   reports tunnel / tailscale / egress status
```

One slot = one VPN-Confinement namespace with its own PIA WireGuard tunnel, plus one
tailscaled confined to it that advertises itself as an exit node. The namespace's only
default route is the tunnel, so a dead tunnel means forwarded traffic fails; it never falls
back to galactica's WAN. That is the kill switch, and it needs no rule of its own.

Clients on an exit node send DNS to it; the slot's tailscaled resolves through the
namespace's `resolv.conf`, which carries PIA's DNS from the `addKey` reply. So DNS leaves
from the chosen country too, and MagicDNS keeps working because tailscaled answers it
itself.

**A device follows its slot.** Clients remember their exit node by node ID, and a slot is
one node whatever its country. Set a phone to slot 1 once; changing slot 1 from Brazil to
the US in HA moves the phone with it.

### Nix surface

```nix
constellation.piaExits.slots = 2;
```

That is the whole nix configuration. Derived per slot `n` (1-based):

| Item | Value | Note |
|---|---|---|
| Namespace | `piax<n>` | VPN-Confinement asserts names under 8 characters |
| Namespace / bridge address | `192.168.(100+n).1` / `.5` | galactica's LAN is `192.168.18.0/24` (see `files.nix`), AirVPN uses `.15`, Transmission's `pia` uses `.16`; `100+` stays clear of all of them |
| Target | `pia-exit-<n>.target` | |
| tailscaled port | `41641 + n` | host tailscaled has 41641 |
| tailscaled state / socket | `/var/lib/tailscale-piax<n>`, `/run/tailscale-piax<n>/tailscaled.sock` | |
| PIA run / state dirs | `/run/pia-x<n>`, `/var/lib/pia-x<n>` | |
| Region file | `/var/lib/pia-exits/slot-<n>` | the slot's region id; absent = Off |

Assertion: `1 <= slots <= 9`.

### Units per slot

All from one helper so Transmission's namespace and the slots share the tunnel code.
Every unit below is `partOf` and wanted by `pia-exit-<n>.target`, and nothing wants that
target: no slot starts at boot or on a deploy by itself; `pia-exits.service` starts,
restarts and stops them. Transmission's `pia` namespace is unchanged and keeps starting at
boot.

- `vpnNamespaces.piax<n>` (VPN-Confinement): WireGuard config from
  `/run/pia-x<n>/wg0.conf`, no port mappings, no open VPN ports, `allowedIngress = []`
  (nothing on the host or LAN needs to reach into a slot).
- `pia-connect-x<n>` (oneshot, host netns): `pia connect` with
  `PIA_REGION_FILE=/var/lib/pia-exits/slot-<n>`, `PIA_RUN_DIR`, `PIA_STATE_DIR`,
  `PIA_NAMESPACE`, `PIA_PORT_FORWARD=0`. `partOf` the namespace unit, as today, so every
  tunnel restart picks a fresh server in the current region. Fails if the file is absent.
- `pia-watchdog-x<n>` service + timer: the existing stale-handshake check, every 2 min.
- `tailscaled-piax<n>`: `vpnConfinement.vpnNamespace = "piax<n>"`;
  `tailscaled --tun=userspace-networking --statedir=… --socket=… --port=<41641+n>`.
  `bindsTo` and `after` the namespace unit. Userspace networking needs no ip_forward or NAT
  in the namespace and never touches host tailscaled, `tailscale0` or table 52.
- `tailscale-piax<n>-up` (oneshot, after tailscaled): on first login, builds
  `<oauth secret>?ephemeral=false&preauthorized=true` into a 0600 file in its
  `RuntimeDirectory` (never on a command line) and runs `tailscale up
  --auth-key=file:<that file> --advertise-exit-node --advertise-tags=tag:service`. On every
  start, `tailscale set --advertise-exit-node --hostname=pia-<region id>` with the region
  read from the region file, so the node is named for its current country (`pia-br-so`).

Non-ephemeral on purpose: an ephemeral node is deleted after an outage and comes back as a
new node, silently unsetting every client's choice, which would also break "a device
follows its slot".

The rename changes the MagicDNS name, not the node ID, so clients keep their selection. A
name set by hand in the admin console overrides `--hostname`; leave the slot nodes'
names alone there.

### Control service (`pia exits serve`)

A new subcommand of the existing `pia` binary, run as `pia-exits.service` (root: it starts
and stops units and reads WireGuard state inside the namespaces), listening on
`127.0.0.1:8592` only, `Restart=always`. Why HTTP: Home Assistant runs natively on
galactica, reaches its loopback, and has REST sensors, `rest_command` and template selects
built in; there is no MQTT broker on galactica, and MQTT discovery (truly dynamic
entities) would need one. Why slots rather than one entity set per country: HA's REST
entities are declared in YAML and cannot appear at runtime, while a fixed set of slot
entities with a dynamic dropdown can.

Config (`PIA_EXITS_CONFIG`, JSON rendered by nix): the slot count and, per slot, the
namespace, target, tailscaled socket and region file.

**Region list.** The service fetches PIA's server list (the same `api::server_list` that
`pia connect` uses) at start and every 6 h, keeping the last good copy. Offered regions are
those not offline with at least one WireGuard server. Each gets a label, PIA's own region
name (`Brazil`, `BR Streaming Optimized`, `US New York`), with ` (virtual)` appended for
PIA's `geo` regions (servers outside the advertised country), sorted, and `(<id>)` appended
on the rare duplicate label. HA works only with labels; the service maps them back to ids.

**API.**

- `GET /status`:
  ```json
  {"options": ["Off", "Brazil", "BR Streaming Optimized", ...],
   "active": 1,
   "slots": [{"slot": 1, "option": "BR Streaming Optimized", "region": "br-so",
              "country": "BR", "state": "up", "handshake_age_s": 41,
              "tailscale": "running", "hostname": "pia-br-so",
              "egress_ip": "…", "egress_country": "BR", "egress_checked": "…"}, ...]}
  ```
- `POST /slots/<n>` with `{"option": "<label>"}`: `"Off"` removes the region file and
  `systemctl stop --no-block pia-exit-<n>.target`; a region label writes the region file
  atomically and `systemctl restart --no-block pia-exit-<n>.target` (restart propagates
  through `partOf`, so `pia connect` re-runs in the new region). Answers at once with the
  slot's new status.
- 404 for a slot outside `1..slots`; 400 for an unknown label or a bad body; 409 when the
  other slot already has that region (pointless, and two nodes would want one hostname).

**At start** the service starts the target of every slot with a region file and stops the
rest, so the choices survive reboots and deploys. A slot with no file is Off; day one both
are Off.

**Status**, refreshed every 30 s, egress every 5 min and right after a change:

| Field | Source |
|---|---|
| `option`, `region`, `country` | region file, region list |
| `handshake_age_s` | `ip netns exec piax<n> wg show <iface> latest-handshakes` |
| `tailscale` | `tailscale --socket=… status --json`: `BackendState == Running`, `Self.Online`, and `0.0.0.0/0` in `Self.AllowedIPs` (the exit route is approved; an unapproved route is advertised but not allowed) |
| `egress_ip`, `egress_country`, `egress_checked` | `https://ipinfo.io/json` fetched inside the namespace (`ip netns exec`) |
| `state` | derived, below |

`state`:

- `off`: no region.
- `starting`: region set or changed less than 2 minutes ago and not yet `up`.
- `up`: handshake under 5 min, tailscale running and approved, egress country equals the
  region's country (for a `(virtual)` region, PIA's advertised country, which is the point
  of picking it).
- `degraded`: the namespace is active but one of those checks fails, or the last egress
  check failed.
- `down`: a region is set but the namespace unit is not active (a failed connect, say; the
  target stays active then, so it is not what is checked).

`state`, label building and mapping, request validation and the region-file handling are
pure functions with unit tests.

**Access.** No token: the port is loopback-only, so anything running on galactica can
change slots, including the board creature's Hermes, which has a terminal there. The worst
it can do is switch countries or turn slots off. If that proves too loose, add a bearer
token from sops.

### Home Assistant entities

Generated by `pia-exits.nix` from `constellation.piaExits.slots`, merged into
`services.home-assistant.config` (`home-assistant.nix` is not edited):

- `rest:` one resource, `GET /status`, `scan_interval: 30`, feeding
  - `sensor.pia_exits`: state `active` (slots on), attribute `options`. Excluded from the
    recorder: the option list is a few KB and never interesting in history.
  - per slot: `sensor.pia_exit_<n>_state`, `sensor.pia_exit_<n>_ip`,
    `sensor.pia_exit_<n>_country`, `sensor.pia_exit_<n>_node` (the Tailscale hostname) and
    `binary_sensor.pia_exit_<n>_working` (`state == up`).
- `rest_command.pia_exit_set`: `POST /slots/{{ slot }}` with `{"option": "{{ option }}"}`.
- `template:` per slot, `select.pia_exit_<n>` named "PIA exit <n>": options from
  `state_attr('sensor.pia_exits', 'options')`, state from the slot's `option`,
  `select_option` calls `rest_command.pia_exit_set` then `homeassistant.update_entity` on
  the REST sensors so the change shows without waiting 30 s.

They go on a dashboard through the UI, like the other dashboards.

A device whose slot is set to Off loses internet until the slot is back or another exit is
chosen: Tailscale holds the traffic rather than leaking it.

### Refactor of the existing PIA module

`modules/hosts/galactica/services/pia.nix` mixes the tunnel (connect, namespace, watchdog)
with port forwarding and consumers. The tunnel half moves into
`modules/hosts/galactica/services/_pia/tunnel.nix`, a function returning the namespace and
units for one tunnel. `pia.nix` keeps its options, port forwarding and consumers and gets
its tunnel from the helper with `portForward = true`, its fixed region and the default
paths, so Transmission's units, paths and addresses are byte-for-byte what they are now
(the unit names `pia-connect` and `pia-watchdog` keep their names for that instance). The
slots live in a new `modules/hosts/galactica/services/pia-exits.nix`.

### `packages/pia` changes

- `PIA_RUN_DIR` and `PIA_STATE_DIR`, defaulting to `/run/pia` and `/var/lib/pia`, replace
  the constants in `src/config.rs` (`WG_CONF_PATH`, `PORT_FILE_PATH`, `STATE_PATH` derive
  from them).
- `PIA_REGION_FILE` as an alternative to `PIA_REGION` (exactly one of them is set).
- `PIA_PORT_FORWARD` (`1` default, `0` for slots). `select_region` rejects a region
  without port forwarding only when it is `1`; `auto` keeps meaning "first port-forward
  region" either way. Most US regions have no port forwarding.
- `PIA_HOOK` and `PIA_IPTABLES` become optional when `PIA_PORT_FORWARD=0`; only
  `portforward` uses them.
- `pia exits serve` (above). A small synchronous HTTP server (`tiny_http`) fits the
  crate, which is already blocking (`reqwest` blocking); no async runtime is added.
- Unit tests: default paths unchanged, custom paths honoured, region file read, a non-PF
  region accepted with PF off and rejected with it on, plus the service's pure functions.

### Tailnet policy (admin console, once; the ACL is not in this repo)

- `"autoApprovers": {"exitNode": ["tag:service"]}`, so a slot's exit route is usable
  without a click.
- Check the user's grants include `autogroup:internet` (basestar is already an exit node,
  so this is probably in place).

### Clients

- blackbird: the Wingpanel Tailscale indicator's exit-node picker, or
  `tailscale set --exit-node=<slot node> --exit-node-allow-lan-access`. `checkReversePath =
  "loose"` is already fleet-wide; nothing to deploy.
- Mac / iPhone / Android: pick the slot's node in Tailscale, turn on "Allow local network
  access".

## PIA connection count

PIA counts each live tunnel: Transmission's `pia` plus every slot that is not Off, so at
most 3 with 2 slots. `pia connect` registers a fresh key on each tunnel restart. Assumed,
not measured: PIA counts connections with a live handshake, not registered keys, so
restarts and country changes do not accumulate connections. Transmission's tunnel has
restarted this way for months without hitting the limit, which is consistent with that.

## Changing the slot count

Raising `slots` adds slots that start Off. Lowering it removes the highest slots: their
units and HA entities go away on deploy, and their region files are ignored. Their
Tailscale nodes stay in the admin console as offline (non-ephemeral); delete them there.

## Failure behaviour

- Tunnel server dies: the watchdog restarts the namespace within ~7 min, `pia connect`
  picks a server from the current list, tailscaled restarts with it. Clients lose internet
  for that window, never leak.
- PIA API unreachable when a slot starts: `pia-connect-x<n>` fails, the slot reads `down`.
  Re-selecting the country in HA retries, and the per-slot watchdog also restarts a
  stopped or failed namespace every 2 min (measured 2026-11-16: after `systemctl stop
  piax1.service` the namespace was back within ~30 s, so a stopped slot heals itself rather
  than staying `down`). The other slot and Transmission are independent.
- PIA server list unreachable for the control service: the last good copy is used; before
  the first success the dropdown offers only Off and the regions currently in use.
- tailscaled crashes: `Restart=on-failure`.
- `pia-exits.service` down: slots keep running as they are; HA shows the entities
  unavailable and cannot change them until it is back.
- `ipinfo.io` unreachable: `egress_*` keep their last values with `egress_checked`, and the
  slot is `degraded` until a check succeeds, since "working" is not proven.
- Peers behind PIA: PIA accepts no unsolicited inbound, but measured 2026-11-16 (raider as
  client) `tailscale ping pia-br-so` is DIRECT via the PIA server's address (~295 ms), not
  DERP.
- Kill switch, measured 2026-11-16: stopping `piax1.service` made client traffic time out and
  never leak.
- Hard-coded DNS: MagicDNS (100.100.100.100) is answered through a slot and the resolver seen
  outside is PIA's, but plain UDP/53 to other resolvers (a device using 8.8.8.8) is dropped
  inside the namespace by VPN-Confinement's `dns-fw` chain, so such devices cannot resolve
  over a slot. DoH/DoT are unaffected.
- Country switch, measured 2026-11-16: BR -> US New York -> BR moved the client with it in
  ~40 s each, its exit-node setting untouched; egress was BR on `br-so`.

## Costs

- Away from home, exit throughput is capped by the home upload, and userspace networking
  is slower than a kernel TUN (well above that cap).
- About 50 MB RAM per running tailscaled; nothing for a slot that is Off.

## Verification

Build: `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`;
`nix build .#pia` (runs its tests).

After deploying galactica:

1. Both `pia-exit-*.target` inactive; `select.pia_exit_1` and `_2` read Off.
2. Set "PIA exit 1" to `BR Streaming Optimized` in HA: `sensor.pia_exit_1_state` goes
   `starting` → `up`, country `BR`, node `pia-br-so`; `tailscale status` on blackbird
   lists `pia-br-so` as an exit node.
3. Set blackbird to that node. `curl ipinfo.io`: a Brazilian address, not the home WAN.
4. DNS leak test from blackbird: PIA resolvers only.
5. `tailscale ping galactica` and a MagicDNS name (`ssh galactica`) still work.
6. Switch slot 1 to a US region in HA without touching blackbird: blackbird's curl now
   shows a US address, and its exit-node setting is unchanged.
7. Stop `piax1.service` by hand: curl on blackbird fails, never shows the home address;
   the slot reads `down`. Re-select the country to bring it back.
8. `systemctl restart pia-exits`: slot 1 keeps its country and stays up.
9. Set slot 1 to Off: the target stops, the node goes offline, the state reads `off`.
10. Transmission still has its forwarded port (`cat /run/pia/forwarded-port`) and
    `pia-portforward-refresh` keeps succeeding; the refactor did not move its paths.
11. `tailscale ping` the slot node from blackbird: record direct vs DERP here.

## Documentation

A short CLAUDE.md section next to the PIA material: the slot model and its cap, the HA
entities and what `state` means, that a device follows its slot, the one-time ACL step,
changing the slot count, and that every slot not Off is one more PIA connection.
