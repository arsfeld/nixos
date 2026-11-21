# Codeman: one dashboard for agent sessions on raider

Date: 2026-11-21

## Goal

One web page from which to start and read Claude Code and Antigravity (`agy`)
sessions, reachable from anywhere, including a work laptop that is not on the
tailnet. Claude Code's own Remote Control works well but only through Claude's
apps and only for Claude; Antigravity's Remote Control is likewise its own
dashboard for its own sessions.

Agents run on **raider** (its checkouts, `~/.claude`, agy's login, the
toolchain), so the dashboard runs there too.

## Decisions

- **Codeman** (`aicodeman` on npm, MIT, github.com/Ark0N/Codeman): a Node 22
  web dashboard that runs each agent CLI in a tmux session, with modes for
  `claude` and `agy` among others. Sessions survive the server restarting.
- **Public through galactica's gateway**, behind Authelia, which stays at the
  fleet's `one_factor` default (decided: no second factor for this host).
- **Codeman's own password** behind Authelia as well.
- **Claude sessions run with `--dangerously-skip-permissions`**, Codeman's
  default (decided: unattended agents are the point). Anyone past both logins
  therefore has an autonomous agent on raider as `arosenfeld`. This is the
  accepted risk; the two passwords are the whole defence.
- **Packaged in nix**, not `npm i -g`: reproducible, rolls back with the system,
  bumped by the weekly routine.

Rejected: Cloudflare Access (a new pattern for one host), Codeman's built-in
Cloudflare tunnel with only its password (one gate in front of a shell), running
Codeman in a container (it needs the host's checkouts, credentials and tools).

## Request path

```
work laptop ─HTTPS─▶ Cloudflare ─tunnel─▶ galactica cloudflared ─▶ Caddy codeman.arsfeld.one
                                                                    │ forward_auth → Authelia (one_factor)
                                                                    ▼
                                         raider.bat-boa.ts.net:8443  tailscale serve, plain HTTP over WireGuard
                                                                    ▼
                                         Codeman on 127.0.0.1:8594   user service, arosenfeld, own password
                                                                    ▼
                                         tmux sessions running claude / agy
```

- `tailscale serve --http=8443`: plain HTTP on the tailnet hop, which WireGuard
  already encrypts, so galactica's Caddy proxies over `http` with no
  `insecureTls` and no certificate question.
- Codeman binds loopback only. Every tailnet peer can still reach :8443 without
  passing Authelia (`tailscale0` is trusted fleet-wide), which is why Codeman's
  password is required and not optional.
- The terminal is a WebSocket. Caddy, cloudflared and `tailscale serve` pass
  upgrades; that Authelia's `forward_auth` admits the upgrade request on its
  cookie is to be verified (acceptance step 4), not assumed.

## Components

### 1. `packages/codeman/package.nix`

`buildNpmPackage` of the `aicodeman` release on `nodejs_22`. `node-pty`'s
native addon builds inside the derivation (python3, a C++ toolchain as needed).
The `codeman` binary is wrapped with `tmux` on `PATH`. Added to the
`just update-packages` list so the weekly routine bumps it.

### 2. `modules/hosts/raider/codeman.nix`

Modelled on `modules/hosts/raider/zellij-web.nix`:

- `systemd.user.services.codeman`: `ConditionUser = "arosenfeld"`,
  `wantedBy = ["default.target"]`, `codeman web --port 8594` (loopback is the
  default bind), `Restart = "on-failure"`.
- `Environment`: `CODEMAN_ALLOWED_HOSTS=codeman.arsfeld.one,raider.bat-boa.ts.net`
  (exact syntax for several hosts confirmed against Codeman's docs during
  implementation), and a `PATH` that includes
  `/etc/profiles/per-user/arosenfeld/bin`, so dashboard sessions use the same
  `claude` and `agy` as the terminal.
- `EnvironmentFile` = the sops secret below.
- `systemd.services.codeman-serve`: system oneshot, after `tailscaled`, running
  `tailscale serve --bg --http=8443 http://127.0.0.1:8594`, restarting on
  failure while tailscaled logs in at boot. It sits beside zellij-web's
  `--https=443` mapping, which it must not disturb.
- The file's header comment says what it is: a public shell running agents
  without permission prompts, gated by Authelia plus Codeman's password.

### 3. Secret

`codeman-env` in `secrets/sops/raider.yaml`, a single line
`CODEMAN_PASSWORD=<random>`; `sops.secrets.codeman-env` with
`owner = "arosenfeld"`, `mode = "0400"`. Generated and stored non-interactively;
the password is given to the user once.

### 4. `modules/hosts/galactica/services/codeman.nix`

Gateway-only `media.services.codeman` with `host = "raider.bat-boa.ts.net"`,
`port = 8443`, no container, Authelia on (no `bypassAuth`). The wildcard DNS
record and cloudflared's wildcard ingress already cover the name: no `infra/`
change.

### 5. Docs

A short CLAUDE.md section: where it runs, the path above, the two logins, the
skip-permissions default, and that a reboot of raider ends running sessions.

## Failure modes

- raider down or rebooting: galactica returns 502; nothing else is affected.
  tmux sessions do not survive a reboot.
- Codeman crashes: `Restart=on-failure`; tmux sessions keep running. That
  Codeman re-attaches them on start is documented but unverified: check it by
  restarting the unit with a session open.
- A Codeman bump that fails to build: handled by the weekly routine like any
  other package (fixed or reverted).

## Acceptance

1. `nix build .#codeman` succeeds and `codeman --version` runs.
2. On raider, `curl -i 127.0.0.1:8594` is refused without the password (401).
3. From galactica, `curl -i http://raider.bat-boa.ts.net:8443` reaches Codeman.
4. From outside the tailnet, `https://codeman.arsfeld.one` redirects to
   Authelia; after both logins the terminal WebSocket stays connected. If
   Authelia blocks the upgrade, the fix (e.g. a rule for the WebSocket path) is
   added here before going further.
5. From the UI, start a Claude session and an agy session in `~/Code/nixos`;
   both run and their output is readable.

Deploy order: raider, then galactica.

## Implementation notes (2026-11-21)

The built system differs from the design above in these places; the code and
CLAUDE.md's "Codeman" section are authoritative.

- **The tailnet hop is `tailscale serve --tcp=8443`, not `--http`.** An HTTP
  serve handler routes on Host and answered 404 for `codeman.arsfeld.one`; the
  gateway cannot rewrite Host, and Codeman must stay on loopback (raider's
  firewall is off; its hook bypass needs a loopback client).
- **PATH is `~/.nix-profile/bin` first.** `/etc/profiles/per-user/arosenfeld`
  does not exist on raider; home-manager installs into the nix profile.
- **`CODEMAN_ALLOWED_HOSTS` is `codeman.arsfeld.one` only.** Codeman trusts
  `*.ts.net` already.
- **The unit has `KillMode=process`**, as Codeman's own unit does: the default
  killed the tmux server, and every session, on each restart.
- **The package strips `CODEMAN_PASSWORD` from the environment tmux starts
  with**, so agent sessions never see the web login.
