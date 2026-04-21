---
date: 2026-04-20
topic: backrest-public-ui-portal
---

# Backrest Public UI Portal

## Problem Frame

The current `backrest.arsfeld.one` landing page is publicly reachable
(via storage's cloudflared tunnel, gated by Authelia) but every card on
it links to `http://<host>.bat-boa.ts.net:9898/` — a tailnet-only URL.
On a phone where Tailscale is flapping (mobile data, captive portals,
MagicDNS lag) the portal loads but the click-through fails. The user
wants one bookmark that works regardless of client-side Tailscale
state, with the live Backrest UI for any host one click away.

The fix has two layers:

1. Make each per-host Backrest UI publicly reachable behind Authelia.
2. Wrap the per-host UIs in a single portal page so the user
   experiences "one app with a host switcher", not "four bookmarks".

The original brainstorm `docs/brainstorms/2026-04-20-unify-backups-backrest-brainstorm.md`
scoped the per-host subdomains as in-scope for Phase A, but the landed
implementation in `hosts/storage/services/backrest-portal.nix` punted
to a tailnet-only static landing page. This brainstorm picks that
thread back up and adds the iframe portal layer.

## Requirements

**Per-host public access**
- R1. Each host running `constellation.backrest` is reachable at
  `backrest-<host>.arsfeld.one` from the public internet.
- R2. Every per-host subdomain is gated by Authelia using the same
  forward-auth pattern as other internal services (`*.arsfeld.one`).
- R3. _Cut._ (Defense-in-depth via Backrest's own auth was
  considered and dropped — see Key Decisions. Authelia is the
  sole public gate; tailnet binding remains the upstream constraint.)
- R4. _Cut._ (The literal host list in `backrest-portal.nix`
  stays. See Key Decisions.)

**Portal experience**
- R5. `backrest.arsfeld.one` serves a single-page portal with a host
  switcher (sidebar or header tabs) and an iframe area that loads the
  selected host's Backrest UI from its `backrest-<host>.arsfeld.one`
  subdomain.
- R6. The portal preserves SSO across host switches — the user does
  not re-authenticate when changing hosts (Authelia session cookie
  scoped to `*.arsfeld.one`, which is already the case).
- R7. The portal works on a phone-sized viewport (the primary target
  device). Sidebar collapses or moves to a top selector on narrow
  screens.
- R8. The portal exposes a fallback "open in new tab" affordance per
  host, in case iframing breaks for any reason (browser policy, CSP
  edge cases).
- R9. The portal indicates the currently selected host clearly,
  including in the page title or URL fragment so a bookmark to a
  specific host's view round-trips correctly.

**Trust model and safety**
- R10. The per-host subdomains are listed in the central service
  registry (`bypassAuth = false`) so the existing Authelia + Caddy
  flow applies without bespoke configuration.
- R11. Storage's Caddy is authoritative for framing headers on the
  per-host Backrest vhosts: it must emit `Content-Security-Policy:
  frame-ancestors https://backrest.arsfeld.one` and unconditionally
  strip any upstream `X-Frame-Options` header from the Backrest
  daemon's response. The iframing contract does not depend on
  whatever Backrest itself emits today or in future versions.
- R12. No new public ingress points are added beyond the
  `backrest-<host>.arsfeld.one` subdomains — the Backrest daemons
  continue to bind tailscale0 only and storage's Caddy is the only
  edge that proxies them.

## Visual Aid

```
                    +-------------------------------+
                    |   browser on phone (no VPN)   |
                    +---------------+---------------+
                                    |
                                    v
                       https://backrest.arsfeld.one
                                    |
                                    v
                +-----------------------------------+
                |          storage Caddy            |
                |   (Authelia forward-auth gate)    |
                +--+----------+----------+----------+
                   |          |          |
        portal HTML|          |iframe target subdomains
        (sidebar + |          |
         iframe)   |          |
                   |          v
                   |   https://backrest-storage.arsfeld.one
                   |   https://backrest-basestar.arsfeld.one
                   |   https://backrest-pegasus.arsfeld.one
                   |   https://backrest-raider.arsfeld.one
                   |          |
                   |          v
                   |   reverse_proxy http://<host>.bat-boa.ts.net:9898
                   |          |
                   |          v
                   |   per-host backrest daemon (tailnet-only bind)
```

## Success Criteria

- Opening `backrest.arsfeld.one` from a phone on cellular with
  Tailscale off loads the portal, lets the user pick any host, and
  the embedded Backrest UI loads, lists plans, and shows recent
  operations.
- Switching hosts in the portal does not prompt for auth a second
  time within an Authelia session.
- A direct visit to `backrest-<host>.arsfeld.one` (bypassing the
  portal) still works as a standalone Backrest UI behind Authelia.

## Scope Boundaries

- **Storage Caddy is a SPOF for public Backrest access (accepted).**
  When storage is down, no host's Backrest UI is reachable publicly,
  even if the host itself is up. Tailnet remains the recovery path
  during a storage outage. Routing non-storage hosts through their
  own public edges to remove this SPOF is out of scope.
- No cross-host aggregation views (no "all failures across the
  fleet" page). That's the Level-2 status-dashboard idea from the
  brainstorm conversation and is deferred.
- No replacement of Backrest's UI itself. The portal is navigation
  only.
- No upstream Backrest changes (e.g. base-URL/sub-path support).
  Per-subdomain proxying sidesteps the need.
- No changes to backup plans, repos, schedules, or notifications.
- No public exposure of the restic REST servers — only the Backrest
  UI gets a public path.
- No new authentication system. Authelia stays the sole public gate;
  Backrest's built-in auth remains disabled as it is today.

## Considered Alternatives

- **Tailscale Funnel per host**: Each Backrest daemon opts into Funnel
  for `:9898`, getting a public `<host>.<tailnet>.ts.net` URL served by
  Tailscale's edge — no cloudflared, no storage-Caddy hop. Rejected
  because (a) Authelia would not be in the path, dropping SSO and
  forcing per-host Backrest credentials, (b) Funnel URLs are off
  `arsfeld.one`, breaking the SSO cookie scope and bookmark
  consistency, (c) per-host setup spread across the fleet vs one
  central change on storage. Worth revisiting if storage-as-public-edge
  becomes a problem (see SPOF caveat under Scope Boundaries).
- **Status-only public page (no live UI)**: Storage polls each
  Backrest's API and renders a read-only "last N runs per host" page
  publicly; live UIs stay tailnet-only. Rejected because it doesn't
  let the user act on a failure (force rerun, view full logs) from
  the phone — but kept as the natural next step if the iframe
  approach proves too brittle.
- **Per-host proxy on each host instead of storage**: Each host's own
  Caddy could front its own Backrest publicly. Rejected because (a)
  basestar is the only other host running media.gateway and the
  others would need new public-edge plumbing, (b) it concentrates
  storage's role as the public-edge anchor, which matches today's
  pattern.

## Key Decisions

- **Per-subdomain proxying, not path-based**: Backrest's SPA and
  Connect-RPC API both assume `/` root. One subdomain per host is the
  cheapest way to give each Backrest its own root. Path-based
  (`backrest.arsfeld.one/storage/`) would require HTML/JS rewriting in
  flight or an upstream change; both are out of proportion for the
  goal.
- **Iframes for the portal, not a custom UI**: A custom unified UI
  would mean reimplementing most of Backrest. Iframes give "one URL,
  one navigation, full Backrest UI per host" for the cost of a small
  HTML/JS page. The user can always escape to a per-host subdomain in
  a new tab if iframing misbehaves.
- **Authelia is the sole public gate (no Backrest second factor)**:
  Re-enabling Backrest's built-in auth was considered as a second
  gate but rejected. Reasons: (a) the parent brainstorm describes
  Backrest's built-in auth as "weak", so the marginal security gain
  is small; (b) it conflicts with the "config.json is rewritten on
  every start" invariant in `modules/constellation/backrest.nix`
  unless an interactive first-run flow is reverse-engineered; (c)
  iframe + per-host Backrest login form would re-prompt on every
  host switch, undermining the SSO experience the portal is meant
  to deliver. The accepted defense layers are: Authelia (public),
  Tailscale ACL on the `:9898` upstream (only storage's tailnet
  identity can reach the daemons), and cloudflared as the public
  edge. If Authelia bypass becomes a real concern, address it at
  the Authelia layer (2FA, lockout) rather than reintroducing a
  weak secondary auth.
- **Literal host list, not derived**: The current
  `backrestHosts = [...]` literal in
  `hosts/storage/services/backrest-portal.nix` stays. Deriving from
  `constellation.backrest.enable` was considered and rejected:
  (a) the list has been stable at four entries through the entire
  Backrest migration, (b) any derivation mechanism implicitly
  overloads the existing flag with public-exposure consent, which
  is a different trust decision, (c) editing one literal line when
  blackbird is added later is trivial. Revisit only if Backrest
  hosts proliferate beyond ~8 or rotate frequently.

## Dependencies / Assumptions

- Authelia session cookies are already scoped to `*.arsfeld.one`
  (assumed from the existing SSO behaviour across other internal
  services; planning should confirm).
- Storage's cloudflared tunnel currently terminates `*.arsfeld.one`
  (verified in `hosts/storage/services/cloudflared.nix`), so adding
  `backrest-<host>.arsfeld.one` subdomains needs no DNS/tunnel
  changes — Caddy vhosts are sufficient.
- Storage can reach every Backrest host on the tailnet on port 9898
  (true today; the daemons already bind `tailscale0` and the
  firewall opens 9898 on that interface).

## Outstanding Questions

### Resolve Before Planning

- [Affects R10, R11][Technical] **`media.gateway.services` has no
  per-service header escape hatch today.** R11 cannot be satisfied
  through the central registry as-is. Decide before planning whether
  to (a) extend the gateway submodule with a `responseHeaders` /
  `frameAncestors` option that `__utils.nix` renders, or (b) bypass
  the registry for `backrest-<host>` vhosts and write
  `services.caddy.virtualHosts."backrest-<host>.arsfeld.one"`
  directly (matching how the existing `backrest-portal.nix` does it).
  This decision contradicts R10's "no bespoke configuration" claim
  in case (b); reconcile or relax R10.

### Deferred to Planning

- [Affects R6, R8][Accepted risk] iOS Safari ITP can partition the
  Authelia session cookie in iframe contexts, potentially causing the
  iframe to redirect to `auth.arsfeld.one` and render blank. Accepted
  as a live test after deploy: if it breaks on iPhone, fall back to
  one-tab-per-host via R8's new-tab affordance. Not blocking planning.
- [Affects R5, R7][Design] Host-switcher control type is unresolved:
  sidebar, header tabs, bottom-sheet picker, or dropdown. Pick one
  pattern per breakpoint (e.g., "left sidebar ≥768px, bottom-sheet
  picker on mobile") so the implementer doesn't make the call in
  code without design alignment.
- [Affects R5, R7][Technical] Whether to author the portal as plain
  HTML/CSS/JS (matching today's `backrest-portal.nix` style) or pull
  in a small framework. Default to plain HTML — the surface is tiny
  (host list + iframe + selector) and a framework adds carrying cost.
- [Affects R5, R8][Design] Iframe-area state coverage: (1) initial /
  no host selected, (2) loading (iframe fetch in flight), (3) load
  success, (4) host unreachable / Caddy 502 / TCP timeout (raider
  asleep), (5) Authelia session expired mid-iframe (auth.arsfeld.one
  redirect inside the frame, may render blank if Authelia sets
  X-Frame-Options). Specify visible content for each state and
  whether the open-in-new-tab affordance is always visible per host
  or only on failure.
- [Affects R5][Information architecture] Phone viewport budget: the
  portal's host switcher chrome plus Backrest's own SPA nav stack
  on a 390px screen. State a chrome budget (e.g., "portal header
  ≤48px, iframe takes remaining viewport") and acknowledge that
  Backrest's own internal nav may be unusable in a narrow iframe —
  mitigation: open-in-new-tab is the escape, and that's fine.
- [Affects R9][Technical] URL fragment scheme: the portal's fragment
  captures only "which host," not Backrest's own internal SPA
  state. Bookmark guarantee is host-only round-trip; in-Backrest
  navigation is not preserved. Document this explicitly so
  implementer doesn't try to wire postMessage.
- [Affects R12][Reliability] **raider is a desktop, not always-on.**
  When raider is asleep, the iframe shows a Caddy 502 / TCP timeout
  after 30-120s. Decide: (a) classify hosts as "always-on" vs
  "opportunistic" in the registry and only iframe always-on hosts,
  with an explicit "raider — last seen N hours ago" state for
  opportunistic ones, or (b) accept the slow-failure UX and surface
  the existing shared error page clearly. The current implicit
  behavior is (b) by accident.
- [Affects R12][Technical] Visual aid shows
  `reverse_proxy http://<host>.bat-boa.ts.net:9898` (FQDN), which
  matches the existing tailnet pattern. Pin the form in the
  registry entry: either `host = "<name>.bat-boa.ts.net"` (FQDN,
  resolver-search-domain-independent) or extend the gateway helper
  with a `tailnetSuffix` join. Record which.
- [Affects R10][Architecture] Confirm the `backrest-<host>`
  `media.gateway.services` entries are added to **storage's**
  configuration, not the host being backed up. basestar also runs
  `media.gateway` (with a different authHost), so the location of
  the registration matters for which Caddy serves the vhost.

## Next Steps

-> /ce-plan for structured implementation planning.
