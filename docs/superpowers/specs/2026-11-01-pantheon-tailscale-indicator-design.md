# Tailscale indicator for Pantheon

## Problem

Nothing in Pantheon's panel says whether Tailscale is up, and turning it off or
routing through an exit node means `sudo tailscale …` in a terminal. macOS and
Windows have a menu-bar Tailscale item for this; Pantheon should have a native
one.

Goal: on every host with Tailscale and Pantheon (raider and blackbird today), a
Wingpanel icon always shows Tailscale's state, and its popover turns Tailscale
on and off and picks an exit node, without sudo.

Out of scope, by decision: a peer list, copying addresses, login flows,
`ExitNodeAllowLANAccess`, and notifications.

## Rejected alternatives

- **`trayscale`** (nixpkgs). Zero code, but it renders in namarupa's
  AppIndicator tray with a DBusMenu rather than a native popover, and runs a
  whole GTK4 app as a long-lived user process for one switch. Rejected for
  GameMode for the same reasons
  (`2026-10-31-pantheon-gamemode-indicator-design.md`).
- **A native plugin driving the `tailscale` CLI.** Less HTTP code, but it polls
  `tailscale status --json` (state lags by the interval and wakes the CPU),
  spawns processes from inside the panel, and every call prints the
  client/daemon version-mismatch warning.

## Measured on raider (tailscaled 1.104.1)

- `/run/tailscale/tailscaled.sock` is `0666`; unprivileged `GET`s of
  `/localapi/v0/prefs` and `/localapi/v0/status` succeed with
  `Host: local-tailscaled.sock`.
- `GET /localapi/v0/watch-ipn-bus?mask=22` (NotifyInitialState |
  NotifyInitialPrefs | NotifyNoPrivateKeys) streams one JSON `Notify` per line;
  the first carries `"State":6` (Running) and the full `Prefs`.
- An unprivileged `PATCH /localapi/v0/prefs` returns **403**. tailscaled
  authorizes writes by the caller's uid, which is what `--operator` grants.
- `OperatorUser` is unset on raider.
- The tailnet has one exit node, `basestar`.
- `elementary-icon-theme` has `network-vpn-{,acquiring-,disabled-,
  disconnected-,no-route-}symbolic` and nothing meaning "exit node".

## Design

### Components and placement

A native Wingpanel indicator plugin, `libtailscale-indicator.so`, source and
derivation in `packages/wingpanel-indicator-tailscale/`:

- `src/Indicator.vala`: the `Wingpanel.Indicator` subclass. It holds the
  panel icon, the popover and the `get_indicator` entry point, which returns
  `null` for the `GREETER` server type.
- `src/LocalApi.vala`: tailscaled client. A `Soup.Session` whose
  `remote-connectable` is a `GLib.UnixSocketAddress` for
  `/run/tailscale/tailscaled.sock`, every request sent with
  `Host: local-tailscaled.sock`. Exposes `watch()` (the IPN bus stream),
  `status()`, `set_running(bool)` and `set_exit_node(string id)`.
- `src/Model.vala`: pure functions from parsed JSON (json-glib) to a small
  state record: backend state, `WantRunning`, exit-node id and name, first
  IPv4, health messages, and exit-node candidates (id, hostname, online).
- `src/icons/tailscale-*-symbolic.svg` plus a GResource: Tailscale's own mark
  (the 3x3 dot grid, its T solid and the rest faint), one variant per state.
  Symbolic, so GTK recolours them to the panel's foreground.
- `tests/TestModel.vala` and `tests/fixtures/*.json`: unit tests on fixtures
  captured from 1.104.1.
- `meson.build` and `package.nix`: as the gamemode indicator's, plus `libsoup_3`
  and `json-glib`, installed into `lib/wingpanel/`, tests in `checkPhase`.
- `CLAUDE.md`: the visual loop for this indicator, pointing at
  `modules/desktop/pantheon-dock/CLAUDE.md` for screenshot details.

Wiring is the feature `pantheon-tailscale`, in
`modules/desktop/pantheon-tailscale.nix`, imported by `desktop.nix` beside
`pantheon-gamemode`. It is gated on `services.tailscale.enable &&
services.desktopManager.pantheon.enable`, both upstream options, so the VM test
can import it alone. It does two things:

- adds `pkgs.callPackage ../../packages/wingpanel-indicator-tailscale/package.nix {}`
  to `services.desktopManager.pantheon.extraWingpanelIndicators`;
- adds `services.tailscale.extraSetFlags = ["--operator=arosenfeld"]`. The list
  merges with `common.nix`'s `--ssh` and is reapplied on every activation. The
  grant lives here rather than in `base` because only this indicator uses it.

The code name is `tailscale`. Wingpanel gives unknown code names order 1, so it
sits right of the tray and left of the system indicators, as gamemode does.

### Panel icon

Always visible.

| State | Icon |
|---|---|
| Running, no exit node | `tailscale-symbolic`: the mark |
| Running via an exit node | `tailscale-exit-node-symbolic`: the mark, an outbound arrow in place of its top-right dot |
| Starting (5) | `tailscale-acquiring-symbolic`: only the T's bar solid |
| Stopped (4) | `tailscale-disabled-symbolic`: every dot faint |
| NeedsLogin (2), NeedsMachineAuth (3), tailscaled unreachable, NoState (0), InUseOtherUser (1), unknown value | `tailscale-disconnected-symbolic`: every dot faint, struck through |

All are bundled; the tooltip still tells the last row's cases apart.

### Popover

Top to bottom:

1. **Tailscale** with a `Granite.SwitchModelButton` showing `WantRunning`.
2. A status line: `Connected · <IPv4>`, `Off`, `Starting…`, `Needs login`, or
   `tailscaled not running`.
3. Only while Running: **Exit node**, radio rows for **None** and each
   `ExitNodeOption` peer by hostname, sorted. Offline candidates are shown
   insensitive. The active row is the one matching `Prefs.ExitNodeID`.
4. Health messages from `/status`, as dim labels, only when present.
5. After a failed write, a red line below the header naming the HTTP status,
   e.g. `Not permitted (403): is --operator set?`. Cleared by the next
   successful write or by closing the popover.

### Data flow

- **Push.** On load, `watch()` opens the IPN bus with `mask=22` and reads it
  with `DataInputStream.read_line_async`. Each `Notify` with a `State` or
  `Prefs` updates the record, and the icon and any open popover follow.
- **Reconnect.** On EOF or error the state becomes unreachable and the stream
  reopens after 1 s, doubling to a 30 s cap, reset by the first successful
  line. This covers tailscaled restarts and starting before it.
- **Pull.** `opened()` starts an async `status()` for the IPv4, health and
  exit-node candidates. Never from a signal handler.
- **Write.** The switch sends `PATCH /prefs` with
  `{"WantRunningSet":true,"WantRunning":<bool>}`. A radio row sends
  `{"ExitNodeIDSet":true,"ExitNodeID":"<id or empty>"}`. Nothing is optimistic:
  controls show only what the bus reports, so a refused write snaps back on its
  own. Handlers that set a control from the bus are blocked while doing so,
  so updating it never sends a write.
- **Logging.** Each record change logs one `message` line (`info` is hidden by
  default), e.g. `Tailscale: Running, exit node basestar` or
  `Tailscale: unreachable`. Each popover `/status` logs
  `Tailscale status: <n> exit node candidate(s)`. The VM test reads these.

### Failure behaviour

- All socket I/O is async, so the panel's main loop never blocks on tailscaled.
- The plugin runs inside Wingpanel, so a crash takes the panel with it. `Model`
  returns nullable fields for anything missing or mistyped, an unknown `State`
  maps to unreachable, and nothing indexes into JSON arrays unchecked. This is
  the defence against a LocalAPI shape change after a nixpkgs bump.
- A failed write shows the error line, and the state stays whatever the bus says.
- A failed `/status` leaves the switch and status line from bus state, with
  an empty exit-node section.

### The trade the switch brings

Turning Tailscale off on a host cuts Tailscale SSH into it, so deploys to it
fail until it is back on. On raider, the deploy driver, every remote target
becomes unreachable too. That is the switch working, and the indicator does not
guard against it.

## Testing

1. **Unit tests** (meson `test()`, in `checkPhase`):
   - a `Notify` → record for each `State` value, including an unknown one →
     unreachable;
   - a `/status` → exit-node candidates (one online, one offline) and the first
     IPv4;
   - a `Prefs.ExitNodeID` → the matching peer's hostname, or the raw id if no
     peer matches;
   - JSON missing `Prefs` or `Peer` → defaults, no crash.
2. **VM test** `tests/pantheon-tailscale-test.nix`, exposed as
   `checks.x86_64-linux.pantheon-tailscale-test`, modelled on
   `pantheon-gamemode-test` (LightDM autologin, `pantheon-wayland`), with
   `services.tailscale.enable` and the module imported. There is no control
   server, so the node waits at NeedsLogin. Asserts from the journal:
   - wingpanel's `list-indicators` names `tailscale`, and the log reports
     `NeedsLogin`;
   - `systemctl stop tailscaled` → `Tailscale: unreachable`; `start` → the
     stream reconnects and logs `NeedsLogin` again;
   - as the session user, `tailscale down` → `Stopped`, which proves the bus
     push and the `--operator` grant together; `tailscale up --timeout=1s` (expected to fail without a control server) returns
     it to `NeedsLogin`;
   - `open-indicator` with `tailscale` → a `Tailscale status:` line;
   - no warning or critical from the indicator's log domain, and wingpanel
     kept its PID throughout.

   Exit-node selection needs a control server, so the unit tests and
   acceptance cover it.
3. **Visual loop on raider:** `just pantheon::panel-run` takes the indicator's
   package name (`gamemode` by default, so existing use is unchanged) instead of
   hardcoding `wingpanel-indicator-gamemode`. Then the `open-indicator` action
   and `just pantheon::shot` on the panel's top right, in each of Running, Off
   and exit-node states.
4. **Acceptance after deploy, on raider:** pick `basestar` in the popover; the
   icon changes within a second and `curl -s ifconfig.me` prints
   `168.138.71.109`. Pick None, switch off and back on, and `systemctl --failed`
   stays clean.
