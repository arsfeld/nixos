---
title: "feat: Public UI portal for Backrest with per-host subdomains"
type: feat
status: active
date: 2026-04-20
origin: docs/brainstorms/2026-04-20-backrest-public-ui-portal-brainstorm.md
---

# feat: Public UI portal for Backrest with per-host subdomains

## Overview

Make every host's Backrest UI reachable from the public internet behind
Authelia, then replace the current static landing page at
`backrest.arsfeld.one` with a single-page iframe portal that switches
between hosts. Closes the existing footgun where the landing page is
public but its links go to tailnet-only URLs that 404 from any device
where Tailscale is flapping.

The fix has two on-disk layers:

1. **Per-host public vhosts.** Storage's Caddy gains
   `backrest-<host>.arsfeld.one` for each Backrest host, gated by the
   same Authelia forward-auth as every other internal service.
2. **Iframe portal.** `backrest.arsfeld.one` becomes a single HTML
   page with a host switcher (top row of pill buttons) and an iframe
   that loads the selected host's public subdomain. Plain HTML + CSS
   + a few lines of JS — no framework.

## Problem Frame

Today's `backrest.arsfeld.one` (`hosts/storage/services/backrest-portal.nix`)
serves a static card grid whose `href`s point at
`http://<host>.bat-boa.ts.net:9898/`. The page is publicly reachable
behind Authelia, but the click-through targets are tailnet-only.
Result: on a phone where Tailscale is flapping (mobile data, captive
portals, MagicDNS lag), the portal loads but every card 404s.

The user wants one bookmark that works regardless of client-side
Tailscale state, with the live Backrest UI for any host one click
away. See origin: `docs/brainstorms/2026-04-20-backrest-public-ui-portal-brainstorm.md`.

## Requirements Trace

Requirement IDs match the brainstorm (R3 and R4 were cut during
brainstorm review and remain cut here).

- R1. Each host running `constellation.backrest` is reachable at
  `backrest-<host>.arsfeld.one` from the public internet.
  (Unit 1)
- R2. Every per-host subdomain is gated by Authelia using the same
  forward-auth pattern as other internal services. (Unit 1)
- R5. `backrest.arsfeld.one` serves a single-page portal with a host
  switcher and an iframe area. (Unit 2)
- R6. The portal preserves SSO across host switches on browsers that
  permit cross-subdomain cookies in iframe contexts. (Unit 1 + Unit 2;
  cookie scope already correct per `hosts/storage/services/auth.nix`.
  iOS Safari ITP is the known exception — see Risks.)
- R7. The portal works on a phone-sized viewport. (Unit 2)
- R8. Per-host "open in new tab" affordance is always visible.
  (Unit 2)
- R9. Selected host is encoded in the URL fragment so a bookmark
  round-trips host-only state. (Unit 2)
- R10. Per-host subdomains are written directly via
  `services.caddy.virtualHosts.<name>` (bypassing the central
  registry, which has no escape hatch for custom response headers).
  They reuse the same Authelia `forward_auth` body and
  `useACMEHost = "arsfeld.one"` wiring as the registry, matching
  existing precedent in `hosts/storage/services/backrest-portal.nix`
  and `hosts/storage/services/isponsorblock.nix`. See Key Technical
  Decisions. (Unit 1)
- R11. Storage's Caddy emits CSP `frame-ancestors
  https://backrest.arsfeld.one` and unconditionally strips any
  upstream `X-Frame-Options`. (Unit 1)
- R12. No new ingress points beyond `backrest-<host>.arsfeld.one`.
  Daemons keep binding `tailscale0` only. (No code change required;
  invariant preserved.)

## Scope Boundaries

- **Storage Caddy is a SPOF for public Backrest access.** Accepted in
  the brainstorm. When storage is down, no host's Backrest UI is
  reachable publicly; tailnet remains the recovery path.
- No cross-host aggregation views (no "fleet status" page).
- No replacement of Backrest's UI itself — the portal is navigation.
- No upstream Backrest changes; per-subdomain proxying sidesteps the
  base-URL problem.
- No changes to backup plans, repos, schedules, or notifications.
- No public exposure of the restic REST servers.
- No second auth gate (R3 cut). Authelia is the sole public gate;
  Backrest's built-in auth stays disabled as it is today.
- No derived host list (R4 cut). The literal four-element list stays.

### Deferred to Separate Tasks

(none — all scope lands in this plan)

## Context & Research

### Relevant Code and Patterns

- `hosts/storage/services/backrest-portal.nix` — existing static
  landing page. Already uses the direct-vhost pattern with a
  hand-rolled `forward_auth` block and shows the canonical Authelia
  forward-auth incantation in this repo. Will be rewritten in Unit 2.
- `hosts/storage/services/isponsorblock.nix` — second example of the
  direct-vhost pattern with custom response headers (`X-Frame-Options
  SAMEORIGIN`). Confirms that bypassing `media.gateway.services` for
  per-vhost header customization is an established convention.
- `modules/media/__utils.nix` `generateHost` (lines 87–172) —
  documents what the central registry produces. Confirms there is no
  per-service header escape hatch and no way to strip upstream
  headers, so the direct-vhost pattern is required for R11.
- `modules/constellation/backrest.nix` — daemon module. No changes
  needed: daemons already bind `tailscale0:9898` with the firewall
  open on tailscale0, so storage's Caddy reaches each host over the
  tailnet.
- `hosts/storage/services/cloudflared.nix` — wildcard ingress for
  `*.arsfeld.one` already terminates at `localhost`, so adding new
  `backrest-<host>.arsfeld.one` subdomains needs no DNS or tunnel
  config changes.
- `hosts/storage/services/auth.nix` — Authelia session cookie scoped
  to `arsfeld.one`, confirming SSO carries across the new
  subdomains.
- `hosts/storage/services/default.nix` — imports list; new file
  added in Unit 1 must be added here.

### Institutional Learnings

- `~/.claude/projects/-home-arosenfeld-Projects-nixos/memory/` —
  general guidance about avoiding `find /nix/store`. No directly
  applicable learnings in `docs/solutions/` (the directory does not
  exist in this repo).

### External References

- None gathered. The work is well-patterned in-repo — two existing
  examples of the exact direct-vhost-with-custom-headers shape, plus
  the existing portal file as the rewrite target.

## Key Technical Decisions

- **Bypass `media.gateway.services` for per-host subdomains.** R11 needs
  CSP `frame-ancestors` and X-Frame-Options stripping; the central
  registry's `generateHost` (`modules/media/__utils.nix`) cannot
  express either. Two existing files in the same directory
  (`backrest-portal.nix`, `isponsorblock.nix`) already use the
  direct-vhost pattern, so this matches convention. R10's
  "no bespoke configuration" claim is relaxed: vhosts are direct
  but they reuse the same `forward_auth` body and `useACMEHost
  = "arsfeld.one"` pattern as the registry, so the trust contract
  is preserved.
- **Host list stays literal.** Both files (per-host subdomains in Unit 1,
  portal in Unit 2) inline the same four-element list:
  `[ "storage" "basestar" "pegasus" "raider" ]`. Two literals stay
  in sync by convention; if they ever drift, the visible symptom is
  obvious (a portal pill that 404s, or a vhost with no portal
  card). Per the R4 cut, derived lists are explicitly out.
- **`reverse_proxy` upstream form: FQDN, except storage = localhost.**
  Each per-host vhost reverse-proxies to
  `http://<host>.bat-boa.ts.net:9898`, which uses MagicDNS via
  Tailscale and is resolver-search-domain-independent. Storage's own
  vhost proxies to `http://localhost:9898` instead, avoiding a
  pointless tailnet loopback.
- **Caddy strips `X-Frame-Options` at the top-level `header`
  directive, not inside `reverse_proxy`.** A top-level `header
  { -X-Frame-Options ... }` runs on every response Caddy emits,
  including upstream-proxied responses *and* Caddy-generated error
  pages and redirects. `header_down` inside `reverse_proxy` only
  affects upstream responses and would be dead code on any
  forward_auth 302. Pick one mechanism (top-level), drop the other.
  This makes the CSP `frame-ancestors` directive the sole framing
  authority regardless of what Backrest emits today or in any
  future version.
- **Host switcher is a top row of pill-shaped sibling links that
  wraps on narrow screens.** No sidebar, no bottom-sheet, no
  dropdown — single pattern across all viewports keeps JS and CSS
  minimal. Each pill is a *pair* of sibling `<a>` elements wrapped
  in a container `<div role="group">`: the primary anchor uses
  `href="#host=<name>"` (clicking swaps the iframe via JS, falls
  back to a hash-only navigation without JS), and the secondary
  anchor uses `target="_blank"` with the full
  `https://backrest-<name>.arsfeld.one/` URL (always opens in a
  new tab — the R8 fallback). Both elements are `<a>` so there is
  no nested-interactive HTML5 violation, no event-bubbling
  ambiguity, and the new-tab affordance never accidentally swaps
  the iframe. Active state: `aria-current="page"` on the primary
  anchor, plus a filled accent-color background. Hover state: a
  border-color brighten matching the existing card hover. Focus
  state: `outline: 2px solid var(--accent)` for keyboard
  accessibility. Minimum tap target: 44×44px on the touch surface.
- **URL fragment is host-only.** Format: `#host=<name>`. The
  brainstorm noted explicitly that in-iframe Backrest navigation is
  not preserved across portal reloads. No `postMessage`
  choreography.
- **Plain HTML/CSS/JS, no framework.** Mirrors the existing
  `backrest-portal.nix` style. The page surface is one header, four
  pill buttons, one iframe, ~30 lines of JS. A framework would add
  carrying cost for no benefit.
- **raider on the host list, with no special "asleep" handling.**
  When raider is suspended, the iframe surfaces a Caddy 502 / TCP
  timeout after the default upstream timeout. The always-visible
  "open in new tab" pill icon is the user's escape; Caddy's shared
  error pages handle the rest. Brainstorm option (b).

## Open Questions

### Resolved During Planning

- **Should R10/R11 be expressed through the central service
  registry?** No. Use the direct-vhost pattern (option b in the
  brainstorm). Existing precedent: `isponsorblock.nix`,
  `backrest-portal.nix`. Relax R10 accordingly.
- **What host-switcher control type?** Top row of pill buttons that
  wraps on narrow viewports. One pattern at all sizes.
- **`reverse_proxy` upstream form?** Tailnet FQDN
  `<host>.bat-boa.ts.net`; localhost for storage's own vhost.
- **Where do the new vhosts live?** In storage's
  `hosts/storage/services/` directory, since storage is the
  cloudflared edge for `*.arsfeld.one`.

### Deferred to Implementation

- **iOS Safari iframe SSO behavior.** Accepted risk in the
  brainstorm. If ITP partitions the Authelia session cookie inside
  the iframe and the iframe goes blank on iOS Safari, the
  always-visible "open in new tab" affordance is the fallback. No
  pre-deploy spike planned.
- **Backrest's actual response headers at runtime.** Caddy strips
  `X-Frame-Options` unconditionally, so the answer doesn't change
  the plan. Worth eyeballing once after deploy via
  `curl -I https://backrest-storage.arsfeld.one/` to confirm the
  emitted headers match expectations.
- **ACME cert provisioning.** Storage already has the
  `arsfeld.one` ACME host wired (`useACMEHost = "arsfeld.one"`
  works for every existing subdomain in storage's services). No
  new cert work expected.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance
> for review, not implementation specification. The implementing agent
> should treat it as context, not code to reproduce.*

Per-host subdomain vhost shape (one per host in the literal list):

```caddyfile
backrest-<host>.arsfeld.one {
  tls <ACME from arsfeld.one>

  import errors
  forward_auth <authelia> { ... copy_headers Remote-* }

  header {
    Content-Security-Policy "frame-ancestors https://backrest.arsfeld.one"
    -X-Frame-Options
  }

  reverse_proxy http://<host>.bat-boa.ts.net:9898
}
```

Portal vhost gains a strict framing defense too (closes the
clickjacking surface on the portal itself):

```caddyfile
backrest.arsfeld.one {
  ...existing forward_auth + file_server stays...

  header {
    Content-Security-Policy "frame-ancestors 'none'"
    X-Frame-Options "DENY"
  }
}
```

Portal page shape (one HTML doc, served from `backrest.arsfeld.one`):

```html
<header>
  <h1>Backrest</h1>
  <nav class="pills">
    <div role="group" class="pill">
      <a href="#host=storage" data-host="storage">storage</a>
      <a href="https://backrest-storage.arsfeld.one/" target="_blank"
         rel="noopener" aria-label="Open storage in new tab">↗</a>
    </div>
    <div role="group" class="pill">
      <a href="#host=basestar" data-host="basestar">basestar</a>
      <a href="https://backrest-basestar.arsfeld.one/" target="_blank"
         rel="noopener" aria-label="Open basestar in new tab">↗</a>
    </div>
    ...
  </nav>
</header>
<iframe id="host-frame" src="about:blank"></iframe>

<script>
  // On load: read #host=name, set iframe.src + mark primary anchor aria-current
  // On primary-anchor click: preventDefault, swap iframe.src, update
  //   location.hash, move aria-current. The secondary (↗) anchor has
  //   no JS handler — browser-native target=_blank handles it.
</script>
```

CSS uses flexbox so the iframe takes `flex: 1` of remaining viewport
height.

## Implementation Units

- [ ] **Unit 1: Add per-host Backrest public Caddy vhosts on storage**

  **Goal:** Make each Backrest UI reachable at
  `backrest-<host>.arsfeld.one` behind Authelia, with iframable
  framing headers under storage's authority.

  **Requirements:** R1, R2, R6, R10, R11, R12

  **Dependencies:** None.

  **Files:**
  - Create: `hosts/storage/services/backrest-public-vhosts.nix`
  - Modify: `hosts/storage/services/default.nix` (add the new
    import)

  **Approach:**
  - Use the direct-vhost pattern
    (`services.caddy.virtualHosts."backrest-${host}.arsfeld.one"`),
    matching `isponsorblock.nix` and the current
    `backrest-portal.nix`.
  - Inline a literal list `backrestHosts = [ "storage" "basestar"
    "pegasus" "raider" ]` at the top of the file.
  - For each host, build a vhost attrset with `useACMEHost =
    "arsfeld.one"` and an `extraConfig` block that includes:
    `import errors`, the same `forward_auth` block as the existing
    portal vhost (using `config.media.gateway.authHost` /
    `authPort`), a Caddy top-level `header` directive setting
    `Content-Security-Policy "frame-ancestors https://backrest.arsfeld.one"`
    and removing `X-Frame-Options` (one mechanism, top-level — see
    Key Technical Decisions), and a `reverse_proxy` to the
    upstream. Use `localhost:9898` when `host == "storage"`,
    otherwise `<host>.bat-boa.ts.net:9898`.
  - Reuse the same `authScheme` conditional already present in
    `backrest-portal.nix` so behavior matches when the auth host is
    on tailnet vs loopback. On storage `authHost = "127.0.0.1"`, so
    the resolved forward_auth target is plain HTTP `127.0.0.1:9091`
    — same as the existing portal.
  - The CSP directive intentionally scopes to `frame-ancestors`
    only. Backrest's own SPA content policy (`script-src`,
    `connect-src`, etc.) is upstream's responsibility and is not in
    scope here.

  **Patterns to follow:**
  - `hosts/storage/services/backrest-portal.nix` — `forward_auth`
    block, `useACMEHost`, `authScheme` conditional, comment style.
  - `hosts/storage/services/isponsorblock.nix` — Caddy `header`
    directive shape and direct-vhost convention.

  **Test scenarios:**
  - *Happy path* — `nix build .#nixosConfigurations.storage.config.system.build.toplevel`
    succeeds with the new file present and imported.
  - *Happy path* — after deploy, `curl -I -L
    https://backrest-storage.arsfeld.one/` returns the Authelia
    redirect (302 to `auth.arsfeld.one`). After authentication, the
    same URL returns 200 with `Content-Security-Policy` header
    containing `frame-ancestors https://backrest.arsfeld.one` and no
    `X-Frame-Options` header.
  - *Happy path* — same check for `backrest-basestar`,
    `backrest-pegasus`, `backrest-raider` subdomains. All four
    resolve, gate at Authelia, then serve Backrest's UI.
  - *Edge case* — `curl -I https://backrest-raider.arsfeld.one/`
    when raider is asleep returns a Caddy 502 or upstream timeout
    after the default deadline. Verify the shared error page
    renders rather than a blank Caddy default.
  - *Integration* — log in via one subdomain in a browser, navigate
    to a different subdomain in the same tab. No re-prompt for
    Authelia (cookie scoped to `arsfeld.one`).

  **Verification:**
  - `just build storage` succeeds.
  - All four `backrest-<host>.arsfeld.one` URLs gate through
    Authelia and serve their respective Backrest UIs after auth.
  - Response headers on each subdomain include CSP `frame-ancestors`
    and have no `X-Frame-Options`.

- [ ] **Unit 2: Replace static landing page with iframe portal**

  **Goal:** `backrest.arsfeld.one` becomes a single-page portal with
  a host switcher and an iframe that loads each host's full Backrest
  UI from its public subdomain.

  **Requirements:** R5, R6, R7, R8, R9

  **Dependencies:** Unit 1 (the portal HTML/JS *builds* independently,
  but the iframe targets are 404 until the per-host subdomains from
  Unit 1 are deployed. End-to-end test scenarios below require Unit 1
  live.)

  **Files:**
  - Modify: `hosts/storage/services/backrest-portal.nix` (full
    rewrite of the `indexHtml` derivation; vhost block keeps its
    existing Authelia gate)

  **Approach:**
  - Keep the existing `services.caddy.virtualHosts."backrest.arsfeld.one"`
    block and its `forward_auth` and `file_server` directives.
  - **Add a framing defense to the portal vhost itself** (closes
    the clickjacking surface flagged in security review): a
    top-level `header { Content-Security-Policy "frame-ancestors
    'none'"; X-Frame-Options "DENY"; }` so `backrest.arsfeld.one`
    cannot itself be embedded by any third-party page.
  - Replace the `indexHtml` derivation (currently the dark
    card-grid) with a single HTML document that has:
    - A header with title "Backrest" and a `<nav class="pills">`
      containing one `<div role="group" class="pill">` per host.
      Each pill is a pair of sibling `<a>` elements: a primary
      anchor `href="#host=<name>"` showing the host name, and a
      secondary anchor `href="https://backrest-<name>.arsfeld.one/"
      target="_blank" rel="noopener"` showing the ↗ open-in-new-tab
      affordance (R8). Sibling structure avoids the HTML5
      nested-interactive violation; the secondary anchor needs no
      JS handler so it cannot accidentally swap the iframe.
    - Pill states: active = primary anchor `aria-current="page"` +
      filled accent background; hover = border accent brighten;
      focus = `outline: 2px solid` accent for keyboard
      accessibility; min tap target 44×44px.
    - An `<iframe id="host-frame" src="about:blank">` that takes
      the remaining viewport via flex layout
      (`flex: 1; width: 100%; border: 0;`). `about:blank` initial
      src avoids the "iframe loads its own portal" flash before JS
      runs.
    - A `<script>` block that on `DOMContentLoaded`: parses
      `location.hash` for `#host=<name>`, defaults to the first
      host in the list if the hash is missing or invalid, sets
      `iframe.src` to the matching `backrest-<name>.arsfeld.one/`,
      and marks the matching primary anchor `aria-current="page"`.
      On primary-anchor click: `event.preventDefault()`, swap
      `iframe.src`, update `location.hash`, move `aria-current`.
      No handler on secondary anchors — browser-native
      `target="_blank"` handles them (R8 fallback).
    - Pills wrap with `flex-wrap: wrap` so no responsive media
      query is needed for narrow phone screens (R7).
  - Inline the same literal `backrestHosts` list as Unit 1.
  - Keep the dark color palette already used by the existing page
    so the portal feels consistent with other internal pages.

  **Patterns to follow:**
  - Existing `hosts/storage/services/backrest-portal.nix` — comment
    style, `pkgs.writeTextDir` usage, dark CSS palette
    (`#1a1b26` / `#7aa2f7` / `#c0caf5`), Caddy vhost shape,
    `authScheme`/`authHost` access via `config.media.gateway`.

  **Test scenarios:**
  - *Happy path* — `just build storage` succeeds.
  - *Happy path* — visiting `https://backrest.arsfeld.one/`
    after Authelia auth shows the portal with all four pill
    buttons. Clicking each pill swaps the iframe to the matching
    host's Backrest UI without a second auth prompt.
  - *Happy path* — `https://backrest.arsfeld.one/#host=basestar`
    loads with the basestar pill active and basestar's UI in the
    iframe. Bookmark round-trips correctly.
  - *Happy path* — clicking the `↗` icon on a pill opens that
    host's subdomain in a new tab (target="_blank"), independent
    of the iframe.
  - *Edge case* — visiting with an invalid hash
    (`#host=does-not-exist`) defaults to the first host in the
    list and does not throw a JS error.
  - *Edge case* — visiting with no hash (`/`) loads the first
    host's iframe by default.
  - *Edge case* — on a narrow phone viewport (~390px wide) the
    pills wrap to a second row and remain tappable; the iframe
    takes the rest of the viewport without overflow.
  - *Edge case* — the iframe area for an asleep raider eventually
    shows a Caddy error page (or browser timeout); the portal
    chrome stays interactive so the user can switch to another
    host. The `↗` open-in-new-tab fallback is always available.
  - *Integration* — across host switches in one Authelia session,
    no re-prompt occurs (verifies R6 cookie scope behavior).

  **Verification:**
  - `just build storage` succeeds.
  - The portal at `https://backrest.arsfeld.one/` loads with all
    four hosts available, switches between them in-iframe, and the
    URL fragment updates as expected.
  - On a real phone (with or without Tailscale), the portal page
    plus at least one host iframe loads end-to-end. If iOS Safari
    blanks the iframe due to ITP, the `↗` new-tab affordance is
    used as the documented fallback.

- [ ] **Unit 3: Refresh backup architecture documentation**

  **Goal:** Document the new public access path so a future reader
  understands `backrest.arsfeld.one` is a real iframe portal, not a
  static landing page that punts to tailnet.

  **Requirements:** None directly; closes the doc-coherence loop.

  **Dependencies:** Units 1 and 2.

  **Files:**
  - Modify: `docs/architecture/backup.md` (Backrest section — add a
    short paragraph on the public portal + per-host subdomains and
    the trust model)

  **Approach:**
  - Add or extend a "Web access" subsection under the Backrest
    section: name the entry point `backrest.arsfeld.one`, list the
    per-host subdomains, note that Authelia is the sole public
    gate, and link to the cut-R3 decision (defense-in-depth via
    Backrest's built-in auth was considered and rejected).
  - Note the storage-Caddy SPOF caveat from the brainstorm scope
    boundaries.
  - Cross-link the brainstorm and this plan in the doc's "see
    also" list if one exists; otherwise add a brief line.

  **Patterns to follow:**
  - Existing prose style in `docs/architecture/backup.md`.

  **Test scenarios:**
  - *Test expectation: none* — pure documentation change. Verify
    by reading.

  **Verification:**
  - `docs/architecture/backup.md` describes the public portal at
    `backrest.arsfeld.one`, the four per-host subdomains, and the
    Authelia-only trust model. No stale references remain to
    "tailnet-only landing page" or "click-through requires
    Tailscale."

## System-Wide Impact

- **Interaction graph:** Storage's Caddy gains four new vhosts
  reverse-proxying to per-host Backrest daemons over the tailnet.
  Authelia gains four more relying-party subdomains, but each uses
  the same forward-auth flow as every other internal service.
  cloudflared sees four new subdomains served by the existing
  wildcard ingress.
- **Error propagation:** If a backend host is unreachable, Caddy
  surfaces a 502 / upstream timeout to the iframe. The shared
  `errors` snippet renders the standard error page inside the
  iframe; the portal chrome stays interactive so the user can
  switch hosts.
- **State lifecycle risks:** None — no persistent state added.
  Backrest daemons themselves and their `/var/lib/backrest` state
  are unchanged.
- **API surface parity:** No API changes; the change is purely
  edge-routing. Backrest's own SPA + Connect-RPC API surface is
  unchanged.
- **Integration coverage:** Authelia session cookie sharing across
  the new subdomains is the load-bearing integration concern. R6
  rests on `arsfeld.one` cookie scope (verified in
  `hosts/storage/services/auth.nix`). iOS Safari ITP behavior in
  iframe context is the accepted-risk gap; the open-in-new-tab
  affordance is the documented fallback.
- **Unchanged invariants:** Backrest daemons continue to bind
  `tailscale0:9898` only — no change to
  `modules/constellation/backrest.nix`. The restic REST servers
  remain `--no-auth` on tailnet. The existing
  `backrest.arsfeld.one` Authelia gate is preserved exactly as-is
  in Unit 2.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| iOS Safari ITP partitions the Authelia cookie inside the iframe → blank iframe on iPhone. | Accepted risk per brainstorm. The always-visible per-pill `↗` "open in new tab" affordance is the documented fallback. Validate post-deploy on a real iPhone; if broken, the portal still works as a list of links. |
| Authelia session expires mid-iframe → forward_auth returns 302 to `auth.arsfeld.one`, which almost certainly emits its own `X-Frame-Options: SAMEORIGIN` (Authelia default). The iframe goes blank silently. | Document as known UX gap. The user's escape is the always-visible ↗ affordance: opens the host's subdomain in a new tab where Authelia can render its login page top-level. Re-authenticated session cookie then makes the in-iframe view usable on subsequent loads. Not worth in-flight detection logic. |
| Future Backrest version emits a more restrictive `X-Frame-Options` or `Content-Security-Policy` that conflicts with iframing. | Caddy's top-level `header { -X-Frame-Options }` strips it on every response (including upstream-proxied ones); CSP `frame-ancestors` is asserted independently. Backrest can't override either header at the proxy layer. |
| Backrest UI uses WebSocket / SSE / streaming endpoints that don't tunnel cleanly through cloudflared + Caddy. | Backrest currently uses HTTP/1.1 Connect-RPC; Caddy's vanilla `reverse_proxy` handles streaming responses. Post-deploy smoke test: trigger a manual backup and confirm the operation log streams in real time inside the iframe. If buffering shows up, add `flush_interval -1` or explicit `transport http` config in the vhost block. |
| Iframe never receives an "iframe failed" event — when the upstream is unreachable (raider asleep, host down), the user sees up to ~60s of blank iframe with no portal-side feedback before any error page renders. | Accept the slow-failure UX (per brainstorm). The ↗ affordance is always visible per-pill so the user can escape to a real tab without waiting for the timeout. Worth a future enhancement: a 5-second JS timer that surfaces a "Still loading? Open in new tab" overlay if the `load` event hasn't fired. Not in v1. |
| Storage downtime makes every Backrest UI publicly unreachable. | Accepted in scope boundaries; tailnet remains the recovery path. |
| Future host enables `constellation.backrest` but is missed in the literal list → no portal pill, no public vhost. | Symptom is obvious (host's UI works on tailnet but not via portal). Trade-off accepted in cutting R4 — editing two literal lists when a host is added is trivial. |
| `media.gateway` consumers regress because R10 wording was relaxed. | No actual regression — Unit 1 doesn't touch the central registry. The relaxation is purely documentation: per-host backrest subdomains use a different (preexisting) pattern. |
| **Residual: tailnet-trust boundary.** Backrest daemons bind `tailscale0:9898` with no auth (R3 cut). Any tailnet device — not just storage — can reach 9898 and trigger restores or shell-hook execution as root. This is unchanged from today, but the public portal makes Authelia *look* like a meaningful gate when in fact the backend is fully open on the tailnet. | Document explicitly. Tailscale ACLs are the out-of-repo trust boundary (per `modules/constellation/backrest.nix` design notes). If this assumption ever weakens, R3 must be revisited. |
| **Cert wildcard SPOF.** All four new subdomains share the existing `*.arsfeld.one` ACME wildcard. A renewal failure (DNS-01 issue, Cloudflare API token expiry) breaks all four at once — alongside every other `*.arsfeld.one` service. | Pre-existing failure mode, not introduced here. Worth noting that this plan adds four more visible casualties to a single cert-renewal failure. |

## Documentation / Operational Notes

- After deploy, eyeball the response headers once with
  `curl -I https://backrest-storage.arsfeld.one/` to confirm CSP is
  set and `X-Frame-Options` is absent. Same check on
  `https://backrest.arsfeld.one/` should show `frame-ancestors
  'none'` and `X-Frame-Options: DENY`.
- No monitoring changes — these vhosts inherit Caddy's existing
  access logging. The authenticated identity (Authelia
  `Remote-User`) is forwarded upstream but not logged at the proxy
  layer; per-operation audit trail lives in Backrest's own
  operation log under `/var/lib/backrest/`. If post-incident "who
  triggered this restore" forensics become a need, consider a
  custom Caddy log format that captures `Remote-User` for these
  vhosts.
- No secret changes — Authelia + ACME wildcard already provisioned.
- **Backend dependency**: each Backrest host must keep its daemon
  running with `:9898` open on `tailscale0` (defaults from
  `constellation.backrest`). Disabling `openFirewall` or stopping
  the daemon on any host silently 502s that host's portal pill.
- **Rollback**: `git revert` the Unit 1 + Unit 2 commits and
  redeploy. The previous static landing page returns. No data
  migration, no state to undo.
- Future host enrollment: when `blackbird` (or any new host) gets
  `constellation.backrest.enable = true`, also add it to the
  literal lists in `hosts/storage/services/backrest-public-vhosts.nix`
  and `hosts/storage/services/backrest-portal.nix`. Two-line change.

## Sources & References

- **Origin document:** `docs/brainstorms/2026-04-20-backrest-public-ui-portal-brainstorm.md`
- Related brainstorm (parent): `docs/brainstorms/2026-04-20-unify-backups-backrest-brainstorm.md`
- Related code:
  - `hosts/storage/services/backrest-portal.nix`
  - `hosts/storage/services/isponsorblock.nix`
  - `hosts/storage/services/cloudflared.nix`
  - `hosts/storage/services/auth.nix`
  - `modules/constellation/backrest.nix`
  - `modules/media/__utils.nix`
- Related plans: `docs/plans/2026-04-20-001-feat-unify-backups-under-backrest-plan.md` (parent feature)
