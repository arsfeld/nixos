# PIA exit nodes on galactica

Date: 2026-11-16. Status: design.

## Goal

A whole device (blackbird, a Mac, a phone) sends its internet traffic out of a chosen
country through Private Internet Access while keeping full tailnet access, switched with
Tailscale's own exit-node picker. No new client software and no per-device configuration.

Day one ships one exit, **Brazil** (`pia-br`, for Brazilian streaming services). Other
countries are added or removed later as needed, one attribute each.

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

- Per-app routing, a GUI, or anything installed on clients.
- Switching an exit's country at runtime. A region change is a config edit and a deploy.
- Port forwarding on exits. Only Transmission's existing `pia` namespace forwards a port.

## Design

### Shape

```
client (exit node = pia-br) ──tailnet──▶ tailscaled-pia-br  [galactica, netns `piabr`]
                                            │ userspace networking: forwarded flows are sockets
                                            ▼
                                         wg (PIA region br-so) ──▶ internet
```

One exit = one VPN-Confinement namespace with its own PIA WireGuard tunnel, plus one
tailscaled confined to it that advertises itself as an exit node. The namespace's only
default route is the tunnel, so a dead tunnel means forwarded traffic fails; it never falls
back to galactica's WAN. That is the kill switch, and it needs no rule of its own.

Clients on an exit node send DNS to it; tailscaled-pia-br resolves through the namespace's
`resolv.conf`, which carries PIA's DNS from the `addKey` reply. So DNS leaves from Brazil
too, and MagicDNS keeps working because tailscaled answers it itself.

### Configuration surface

```nix
constellation.piaExits.br = {
  region = "br-so"; # PIA region id
  slot = 1;         # unique per exit, picks addresses and ports; never reuse while live
};
```

Adding a country is one more attribute; removing one is deleting it (see "Removing an exit").

Derived from `<name>` and `slot`:

| Item | Value | Note |
|---|---|---|
| Tailscale hostname | `pia-<name>` | |
| Namespace | `pia<name>` | VPN-Confinement asserts names under 8 characters, so `<name>` is at most 4 |
| Namespace / bridge address | `192.168.(100+slot).1` / `.5` | galactica's LAN is `192.168.18.0/24` (see `files.nix`), AirVPN uses `.15`, Transmission's `pia` uses `.16`; `100+` stays clear of all of them |
| tailscaled port | `41641 + slot` | host tailscaled has 41641 |
| State dir | `/var/lib/tailscale-pia-<name>` | |
| PIA run/state dirs | `/run/pia-<name>`, `/var/lib/pia-<name>` | |

Assertions: `slot` unique and in `1..99`; `<name>` matches `^[a-z]{1,4}$`.

Why an explicit `slot` and not an index derived from the attribute order: adding or removing
an exit would then renumber the others and restart their tunnels and nodes. A slot keeps
every other exit untouched.

### Units per exit

All from one helper so Transmission's namespace and the exits share the tunnel code.

- `vpnNamespaces.pia<name>` (VPN-Confinement): WireGuard config from
  `/run/pia-<name>/wg0.conf`, no port mappings, no open VPN ports, `allowedIngress = []`
  (nothing on the host or LAN needs to reach into an exit namespace).
- `pia-connect-<name>` (oneshot, host netns): `pia connect` with
  `PIA_REGION`, `PIA_RUN_DIR`, `PIA_STATE_DIR`, `PIA_NAMESPACE`, `PIA_PORT_FORWARD=0`.
  `partOf` the namespace unit, as today, so every tunnel restart picks a fresh server.
- `pia-watchdog-<name>` service + timer: the existing stale-handshake check, every 2 min.
- `tailscaled-pia-<name>`: `vpnConfinement.vpnNamespace = "pia<name>"`;
  `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale-pia-<name>
  --socket=/run/tailscale-pia-<name>/tailscaled.sock --port=<41641+slot>`.
  `bindsTo` and `after` the namespace unit, so a tunnel restart restarts it.
  Userspace networking needs no ip_forward or NAT in the namespace and never touches
  host tailscaled, `tailscale0` or table 52.
- `tailscale-pia-<name>-up` (oneshot, after tailscaled): builds
  `<oauth secret>?ephemeral=false&preauthorized=true` into a 0600 file in its
  `RuntimeDirectory` (never on a command line), then
  `tailscale up --auth-key=file:<that file> --hostname=pia-<name>
  --advertise-exit-node --advertise-tags=tag:service`. The key is only consumed on first
  login; state persists after that. Then `tailscale set --advertise-exit-node
  --hostname=pia-<name>` on every start, so a flag change applies on activation.

Non-ephemeral on purpose: clients remember their exit node by node ID, and an ephemeral
node is deleted after an outage and comes back as a new node, silently unsetting every
client's choice.

### Refactor of the existing PIA module

`modules/hosts/galactica/services/pia.nix` mixes the tunnel (connect, namespace, watchdog)
with port forwarding and consumers. The tunnel half moves into
`modules/hosts/galactica/services/_pia/tunnel.nix`, a function returning the namespace and
units for one tunnel. `pia.nix` keeps its options, port forwarding and consumers and gets
its tunnel from the helper with `portForward = true` and the default paths, so
Transmission's units, paths and addresses are byte-for-byte what they are now (the unit
names `pia-connect` and `pia-watchdog` keep their names for that instance).

### `packages/pia` changes

- `PIA_RUN_DIR` and `PIA_STATE_DIR`, defaulting to `/run/pia` and `/var/lib/pia`, replace
  the constants in `src/config.rs` (`WG_CONF_PATH`, `PORT_FILE_PATH`, `STATE_PATH` derive
  from them).
- `PIA_PORT_FORWARD` (`1` default, `0` for exits). `select_region` rejects a region
  without port forwarding only when it is `1`; `auto` keeps meaning "first port-forward
  region" either way. (`br-so` has port forwarding, but a US exit would not.)
- `PIA_HOOK` and `PIA_IPTABLES` become optional when `PIA_PORT_FORWARD=0`; they are only
  used by `portforward`.
- Unit tests for each: default paths unchanged, custom paths honoured, a non-PF region
  accepted with PF off and rejected with it on.

### Tailnet policy (admin console, once; the ACL is not in this repo)

- `"autoApprovers": {"exitNode": ["tag:service"]}`, so a new exit is usable without a click.
- Check the user's grants include `autogroup:internet` (basestar is already an exit node,
  so this is probably in place).

### Clients

- blackbird: the Wingpanel Tailscale indicator's exit-node picker, or
  `tailscale set --exit-node=pia-br --exit-node-allow-lan-access`. `checkReversePath =
  "loose"` is already fleet-wide; nothing to deploy.
- Mac / iPhone / Android: pick `pia-br` in Tailscale, turn on "Allow local network access".

## PIA connection count

PIA counts each live tunnel. Today there is one (Transmission's `pia`); day one adds one,
for two. Every further exit adds one while it is declared, whether or not any client is
using it, which is why exits are declared only when wanted and removed when not. `pia
connect` registers a fresh key on each tunnel restart. Assumed, not measured: PIA counts
connections with a live handshake, not registered keys, so restarts do not accumulate
connections. Transmission's tunnel has restarted this way for months without hitting the
limit, which is consistent with that.

## Removing an exit

Delete its attribute and deploy: its namespace, tunnel, watchdog and tailscaled units are
gone and the PIA connection with them. The Tailscale node stays in the admin console as
offline, because it is non-ephemeral; delete it there (or run
`tailscale --socket=/run/tailscale-pia-<name>/tailscaled.sock logout` before the deploy).
`/var/lib/tailscale-pia-<name>` and `/var/lib/pia-<name>` stay on disk; re-adding the same
name with the same state rejoins as the same node. Its `slot` is free again once the node
is gone.

## Failure behaviour

- Tunnel server dies: the watchdog restarts the namespace within ~7 min, `pia connect`
  picks a server from the current list, tailscaled restarts with it. Clients lose internet
  for that window, never leak.
- PIA API unreachable at boot: `pia-connect-<name>` fails, the namespace and its node stay
  down; clients on that exit get no internet until it recovers. Other exits and
  Transmission are independent.
- tailscaled-pia crashes: `Restart=on-failure`.
- Peers behind PIA: PIA accepts no unsolicited inbound, so clients may reach the exit over
  DERP rather than directly. Measured after deploy with `tailscale ping pia-br` and
  recorded here.

## Costs

- Away from home, exit throughput is capped by the home upload, and userspace networking
  is slower than a kernel TUN (well above that cap).
- About 50 MB RAM per tailscaled.

## Verification

Build: `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`;
`cargo test` in `packages/pia` (via `nix build .#pia`).

After deploying galactica, with blackbird set to `pia-br`:

1. `tailscale --socket=/run/tailscale-pia-br/tailscaled.sock status` on galactica: online,
   offering an exit node; `tailscale status` on blackbird lists `pia-br` as an exit node.
2. `curl ipinfo.io` on blackbird: a Brazilian address, not the home WAN.
3. DNS leak test from blackbird: PIA resolvers only.
4. `tailscale ping galactica` and a MagicDNS name (`ssh galactica`) still work.
5. Stop `piabr.service`: curl on blackbird fails, never shows the home address. Start it again.
6. Transmission still has its forwarded port (`cat /run/pia/forwarded-port`) and
   `pia-portforward-refresh` keeps succeeding; the refactor did not move its paths.
7. `tailscale ping pia-br` from blackbird: record direct vs DERP here.

## Documentation

A short CLAUDE.md section next to the PIA material: what `constellation.piaExits` is, the
one-time ACL step, adding and removing an exit, and the connection-count reason not to
leave unused exits declared.
