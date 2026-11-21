# Codeman Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public `https://codeman.arsfeld.one` that starts and shows Claude Code and Antigravity sessions running on raider.

**Architecture:** Codeman, packaged in nix, runs as arosenfeld's user service on raider at `127.0.0.1:8594`; `tailscale serve --http=8443` publishes it on the tailnet; galactica's gateway proxies `codeman.arsfeld.one` to `raider.bat-boa.ts.net:8443` behind Authelia.

**Tech Stack:** `buildNpmPackage` (Node 22, node-pty, tmux), systemd user unit, sops-nix, `tailscale serve`, `media.services` gateway-only entry.

**Spec:** `docs/superpowers/specs/2026-11-21-codeman-dashboard-design.md`

## Global Constraints

- Commit straight to master; no branches or worktrees.
- Conventional commits, scopes `raider` / `galactica` / `modules`; never mention Claude.
- New files must be `git add`ed (or `git add -N`) before `nix build` can see them.
- Build one host toplevel at a time, never in parallel.
- Deploy from the dev shell: `nix develop -c just deploy <host>`. Raider first, then galactica.
- Codeman listens on `127.0.0.1:8594`; tailnet port `8443` (plain HTTP); public name `codeman.arsfeld.one`.
- Authelia stays at `one_factor`; no `bypassAuth`. No firewall rules.
- Claude sessions keep Codeman's default `--dangerously-skip-permissions`; do not override it.
- Upstream: `github.com/Ark0N/Codeman`, tag `codeman@1.51.1`, npm name `aicodeman`, binaries `codeman`/`aicodeman` → `dist/index.js`.

## Review Focus

1. **zellij-web's `tailscale serve` mapping (`https:443 → 127.0.0.1:8082`) is clobbered** by the new serve command — expected: both mappings present (Task 2, step 6).
2. **Codeman answers the proxied request `403 host not allowed`** because the Host header is `codeman.arsfeld.one` — expected: 401 (Task 2, step 6, and Task 3, step 4).
3. **A dashboard session cannot find `claude` or `agy`** because a user unit's PATH lacks the home-manager profile — expected: both resolve in the service's environment (Task 2, step 6).
4. **Authelia lets the page load but the terminal WebSocket fails** — expected: the terminal stays connected after login (Task 3, step 5).
5. **Restarting the codeman unit loses running sessions** — expected: a session started before `systemctl --user restart codeman` is still listed and attachable after (Task 2, step 7).

---

### Task 1: Package Codeman

**Files:**
- Create: `packages/codeman/package.nix`
- Modify: `justfile` (the `update-packages` default list and its per-package `case`)

**Interfaces:**
- Produces: flake package `.#codeman` (picked up by `packagesFromDirectoryRecursive`, so also `pkgs.codeman` in host modules), providing `bin/codeman`, with `tmux` on the wrapped binary's PATH.

- [ ] **Step 1: Write `packages/codeman/package.nix`**

`buildNpmPackage` with `nodejs = nodejs_22`, `pname = "codeman"`, `version = "1.51.1"`, `src = fetchFromGitHub { owner = "Ark0N"; repo = "Codeman"; tag = "codeman@${version}"; … }` (the repo has `package-lock.json`). `npm run build` (the default `npmBuildScript = "build"`) runs `tsc` and `esbuild` from devDependencies. node-pty's native addon must build: add `python3` and whatever toolchain inputs the build reports. The root `postinstall` only probes for tmux/claude and repairs node-pty on macOS; skip it if it fails in the sandbox, but node-pty's own install script must run. Wrap `bin/codeman` with `--prefix PATH : ${lib.makeBinPath [tmux]}`. `meta.mainProgram = "codeman"`, `license = lib.licenses.mit`. Fill hashes from the fake-hash build errors.

- [ ] **Step 2: Build it**

Run: `git add -N packages/codeman && nix build .#codeman`
Expected: success.

- [ ] **Step 3: Verify the binary and the native module**

Run: `./result/bin/codeman --version`
Expected: `1.51.1`.

Run: `./result/bin/codeman web --port 18594 &` then `curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:18594/`, then kill it.
Expected: an HTTP status (200, or 401 if Codeman demands a password even locally), not a crash about `node-pty` or a missing module in the server output.

- [ ] **Step 4: Add it to `just update-packages`**

Add `codeman` to the default list. Its tags are `codeman@X.Y.Z`, so give it a `case` arm: `codeman) cmd+=(--version-regex 'codeman@(.*)') ;;`.

Run: `nix develop -c just update-packages codeman`
Expected: `codeman` reported current (no change to `package.nix`), not failed.

- [ ] **Step 5: Commit**

```bash
just fmt
git add packages/codeman justfile
git commit -m "feat(modules): package Codeman, a web dashboard for agent CLIs"
```

---

### Task 2: Run Codeman on raider and publish it on the tailnet

**Files:**
- Create: `modules/hosts/raider/codeman.nix`
- Modify: `secrets/sops/raider.yaml` (new key `codeman-env`)

**Interfaces:**
- Consumes: `pkgs.codeman` (Task 1).
- Produces: Codeman at `http://raider.bat-boa.ts.net:8443`, password-protected, accepting Host `codeman.arsfeld.one`.

- [ ] **Step 1: Create the secret**

Generate a password and store it without an editor:

```bash
pw=$(openssl rand -hex 24)
nix develop -c sops set secrets/sops/raider.yaml '["codeman-env"]' "\"CODEMAN_PASSWORD=$pw\""
```

Keep `$pw` to hand to the user at the end; never write it to a file or commit message.

Run: `nix develop -c sops --decrypt --extract '["codeman-env"]' secrets/sops/raider.yaml | cut -d= -f1`
Expected: `CODEMAN_PASSWORD`.

- [ ] **Step 2: Write `modules/hosts/raider/codeman.nix`**

Same shape as `modules/hosts/raider/zellij-web.nix`, defining `configurations.nixos.raider.module`. A header comment says: what this is, the request path from the spec, that it is a public shell whose Claude sessions run without permission prompts, gated by Authelia plus `CODEMAN_PASSWORD`, and that any tailnet peer reaches :8443 past Authelia.

- `sops.secrets."codeman-env"` with `owner = "arosenfeld"`, `mode = "0400"`.
- `systemd.user.services.codeman`: `description`, `unitConfig.ConditionUser = "arosenfeld"`, `wantedBy = ["default.target"]`, `ExecStart = "${lib.getExe pkgs.codeman} web --port 8594"` (loopback is the default bind; if the server log says otherwise, add `-H 127.0.0.1`), `EnvironmentFile = config.sops.secrets."codeman-env".path`, `Restart = "on-failure"`, `RestartSec = 5`.
- `environment`: `CODEMAN_ALLOWED_HOSTS` listing `codeman.arsfeld.one` and `raider.bat-boa.ts.net` in the separator Codeman's docs give; `PATH` = `/etc/profiles/per-user/arosenfeld/bin:/run/current-system/sw/bin:/run/wrappers/bin` so `claude`, `agy`, `git` and `sudo` resolve as in a terminal.
- `systemd.services.codeman-serve`: copy `zellij-web-serve` with `ExecStart = "… tailscale serve --bg --http=8443 http://127.0.0.1:8594"`.

- [ ] **Step 3: Build raider**

Run: `git add modules/hosts/raider/codeman.nix && nix build .#nixosConfigurations.raider.config.system.build.toplevel --no-link`
Expected: success.

- [ ] **Step 4: Commit**

```bash
just fmt
git add modules/hosts/raider/codeman.nix secrets/sops/raider.yaml
git commit -m "feat(raider): run Codeman and publish it on the tailnet"
```

- [ ] **Step 5: Deploy raider**

Run: `nix develop -c just deploy raider`
Expected: activation succeeds; `systemctl --user is-active codeman` → `active`; `systemctl is-active codeman-serve` → `active`.

- [ ] **Step 6: Verify on the tailnet**

| Check | Command | Expected |
|---|---|---|
| password required | `curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8594/` | `401` |
| password works | `curl -s -o /dev/null -w '%{http_code}\n' -u "admin:$pw" 127.0.0.1:8594/` | `200` |
| zellij untouched | `tailscale serve status` | both `https://raider.bat-boa.ts.net` `/ → 127.0.0.1:8082` and `http://raider.bat-boa.ts.net:8443` `/ → 127.0.0.1:8594` |
| reachable from galactica | `ssh galactica.bat-boa.ts.net curl -s -o /dev/null -w '%{http_code}\n' http://raider.bat-boa.ts.net:8443/` | `401` |
| proxied Host accepted | same, adding `-H 'Host: codeman.arsfeld.one'` | `401`, not `403` |
| agents on PATH | `tr '\0' '\n' < /proc/$(systemctl --user show -p MainPID --value codeman)/environ \| grep ^PATH=`, then `env PATH=<that> sh -c 'command -v claude agy tmux'` | three paths |

- [ ] **Step 7: Verify sessions survive a restart**

Through the API (`POST /api/quick-start` or `/api/sessions`, authenticated with `-u admin:$pw`; read the exact body from Codeman's docs) or the UI over the tailnet, start a shell-mode session in `~/Code/nixos`, then `systemctl --user restart codeman`.
Expected: `tmux ls` shows the session throughout, and after the restart Codeman lists it again. If Codeman does not re-attach, record that in the module's header comment and in the CLAUDE.md section (Task 3); it is not a blocker.

---

### Task 3: Public route on galactica, end-to-end acceptance, docs

**Files:**
- Create: `modules/hosts/galactica/services/codeman.nix`
- Modify: `CLAUDE.md` (new `### Codeman (agent dashboard on raider)` section after "PIA exit slots (galactica)")

**Interfaces:**
- Consumes: `http://raider.bat-boa.ts.net:8443` (Task 2).
- Produces: `https://codeman.arsfeld.one`.

- [ ] **Step 1: Write `modules/hosts/galactica/services/codeman.nix`**

A gateway-only `media.services.codeman = { host = "raider.bat-boa.ts.net"; port = 8443; };` in `configurations.nixos.galactica.module`, no `container`, no `bypassAuth`, with a comment pointing to `modules/hosts/raider/codeman.nix` for the why.

- [ ] **Step 2: Build galactica**

Run: `git add modules/hosts/galactica/services/codeman.nix && nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link`
Expected: success. Then confirm the generated vhost proxies to `http://raider.bat-boa.ts.net:8443` with `forward_auth`:
`nix eval --raw .#nixosConfigurations.galactica.config.services.caddy.virtualHosts.\"codeman.arsfeld.one\".extraConfig`
Expected: contains `forward_auth` and `reverse_proxy` to `raider.bat-boa.ts.net:8443` (or the gateway's equivalent form).

- [ ] **Step 3: Commit and deploy galactica**

```bash
just fmt
git add modules/hosts/galactica/services/codeman.nix
git commit -m "feat(galactica): route codeman.arsfeld.one to raider's Codeman"
nix develop -c just deploy galactica
```

Expected: activation succeeds; `ssh galactica.bat-boa.ts.net systemctl is-active caddy` → `active`.

- [ ] **Step 4: Verify the public path is gated**

Run (from raider; it resolves the public name through Cloudflare): `curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://codeman.arsfeld.one/`
Expected: `302` to `https://auth.arsfeld.one/…`. A `200` or `401` from Codeman here means Authelia is not in front: stop and fix before going further.

- [ ] **Step 5: End-to-end in a browser**

In a browser, open `https://codeman.arsfeld.one`, log in to Authelia, then to Codeman (`admin` / `$pw`). Start a Claude session and an agy session in `~/Code/nixos`.
Expected: both terminals render and stay connected for a minute; typing reaches the agent. If the page loads but the terminal WebSocket fails, find the cause (browser network tab, `journalctl -u caddy` on galactica) and fix it in the galactica module before continuing; record what the fix was in the module comment.

- [ ] **Step 6: Document it**

Add the CLAUDE.md section: where Codeman runs (user unit on raider, `127.0.0.1:8594`), the request path (Cloudflare → galactica Caddy + Authelia `one_factor` → `raider.bat-boa.ts.net:8443` via `tailscale serve` → Codeman), the two logins and why both exist (tailnet peers bypass Authelia), that Claude sessions run with `--dangerously-skip-permissions`, that the password is `codeman-env` in `raider.yaml`, that a raider reboot ends sessions while a unit restart does or does not (per Task 2 step 7), and that `just update-packages` bumps it (tag regex `codeman@`). Add `codeman.nix` to raider's host-local module list in the "Features" section.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md modules/hosts/galactica/services/codeman.nix
git commit -m "docs(raider): document the Codeman agent dashboard"
git push
```

Then give the user the Codeman password (`$pw`) once.
