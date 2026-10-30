# raider agents.slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every Claude Code process on raider into a low-priority, memory-capped user slice that gamemode pins to E-cores while a game runs.

**Architecture:** home-manager (`home/home.nix`) defines `agents.slice`, puts the `claude-rc-*` units in it, and wraps the `claude` script on raider so interactive launches enter it through `systemd-run --user --scope`. The shared gaming module gains `backgroundUserSlices`, whose entries the user-side `gaming-boost` script pins to `backgroundCpus` while gamemode is active.

**Tech Stack:** NixOS, home-manager (NixOS module), systemd user slices, gamemode.

Spec: `docs/superpowers/specs/2026-10-30-raider-agents-slice-design.md`

## Global Constraints

- Slice name: `agents.slice` (home-manager attribute `systemd.user.slices.agents`).
- Slice limits: `CPUWeight = 20`, `IOWeight = 20`, `MemoryHigh = "12G"`, no `MemoryMax`.
- Everything in `home/home.nix` is gated on `hostname == "raider"`; other hosts' outputs must not change.
- New shared option: `constellation.gaming.backgroundUserSlices`, `listOf str`, default `[]`. raider sets `["agents.slice"]`.
- Gaming pinning uses `systemctl --user set-property --runtime <slice> AllowedCPUs=<backgroundCpus>`, reset with `AllowedCPUs=`.
- Commit straight to master, conventional commits (`feat(raider): …`, `feat(modules): …`). Never mention Claude as author.
- Run `just fmt` before each commit (the pre-commit hook runs alejandra).

---

### Task 1: agents.slice, claude-rc placement and claude wrapper

**Files:**
- Modify: `home/home.nix` — `llmAgentScripts` (around lines 72-88), `claudeRcServices` (around lines 97-125), the `systemd.user` block (around line 707)

**Interfaces:**
- Produces: user unit `agents.slice` on raider. Task 2 refers to it by that exact name.

- [ ] **Step 1: Confirm the slice is absent (failing check)**

Run:
```bash
nix eval --json .#nixosConfigurations.raider.config.home-manager.users.arosenfeld.systemd.user.slices.agents
```
Expected: error, `attribute 'agents' missing`.

- [ ] **Step 2: Add a shared slice name to the `let` block**

In `home/home.nix`, directly above the `llmAgentScripts = let` line, add:

```nix
  # Every Claude Code process on raider runs in this user slice: the claude-rc
  # units via Slice=, interactive launches via the claude wrapper below. Login
  # session scopes (zellij over SSH) sit beside user@1000.service at equal
  # cpu.weight, and nice does not cross cgroups, so without this an agent's
  # rustc/beam builds compete with the desktop and games as an equal.
  agentsSlice = "agents.slice";
```

- [ ] **Step 3: Wrap the claude script on raider**

Replace `mkAgentScript` inside `llmAgentScripts` with:

```nix
    mkAgentScript = name: let
      pkg = pkgs'.${name};
      binName = pkg.meta.mainProgram or name;
      run = ''nix run github:numtide/llm-agents.nix#${name} -- "$@"'';
    in
      pkgs.writeShellScriptBin binName (
        if binName == "claude" && hostname == "raider"
        then ''
          # Enter ${agentsSlice} unless already inside it (claude-rc units are),
          # and only when the user manager is reachable.
          if ! ${pkgs.gnugrep}/bin/grep -q '/${agentsSlice}/' /proc/self/cgroup &&
            [ -S "''${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
            exec ${pkgs.systemd}/bin/systemd-run --user --scope --slice=${agentsSlice} --collect --quiet -- ${run}
          fi
          exec ${run}
        ''
        else ''
          exec ${run}
        ''
      );
```

- [ ] **Step 4: Put the claude-rc units in the slice**

In `claudeRcServices`, inside `Service = { … }`, add after `RestartSec = 30;`:

```nix
            Slice = agentsSlice;
```

- [ ] **Step 5: Define the slice**

Next to `systemd.user.services =` (around line 707), add a sibling attribute:

```nix
  systemd.user.slices = lib.optionalAttrs (hostname == "raider") {
    agents = {
      Unit.Description = "Claude Code agents, yielding to the desktop";
      # Weights are work-conserving: agents still get every idle core and only
      # lose when the desktop wants CPU or I/O. MemoryHigh throttles and
      # reclaims from the agents first instead of pushing the desktop into
      # swap; with no MemoryMax nothing is OOM-killed by it.
      Slice = {
        CPUWeight = 20;
        IOWeight = 20;
        MemoryHigh = "12G";
      };
    };
  };
```

- [ ] **Step 6: Verify the evaluated config**

Run:
```bash
nix eval --json .#nixosConfigurations.raider.config.home-manager.users.arosenfeld.systemd.user.slices.agents.Slice
nix eval --json .#nixosConfigurations.raider.config.home-manager.users.arosenfeld.systemd.user.services.claude-rc-nixos.Service.Slice
```
Expected: `{"CPUWeight":20,"IOWeight":20,"MemoryHigh":"12G"}` and `"agents.slice"`.

Then check the wrapper body:
```bash
cat $(nix build --no-link --print-out-paths .#nixosConfigurations.raider.config.home-manager.users.arosenfeld.home.path)/bin/claude
```
Expected: the `systemd-run --user --scope --slice=agents.slice` branch is present. Then confirm another host is untouched:
```bash
nix eval --json .#nixosConfigurations.galactica.config.home-manager.users.arosenfeld.systemd.user.slices
```
Expected: `{}` (or an eval error if galactica has no home-manager user, which also means it is untouched).

- [ ] **Step 7: Build raider**

Run: `just build raider`
Expected: success.

- [ ] **Step 8: Commit**

```bash
just fmt
git add home/home.nix
git commit -m "feat(raider): run Claude Code in a low-priority agents.slice"
```

---

### Task 2: gamemode pins background user slices to E-cores

**Files:**
- Modify: `modules/constellation/gaming.nix` — `gamingBoost` script (lines 13-28), options next to `backgroundCpus` (around line 62)
- Modify: `hosts/raider/configuration.nix` — `constellation.gaming` block (around line 124)

**Interfaces:**
- Consumes: user unit `agents.slice` (Task 1).
- Produces: option `constellation.gaming.backgroundUserSlices :: listOf str`.

- [ ] **Step 1: Confirm the option is absent (failing check)**

Run:
```bash
nix eval --json .#nixosConfigurations.raider.config.constellation.gaming.backgroundUserSlices
```
Expected: error, attribute/option missing.

- [ ] **Step 2: Declare the option**

In `modules/constellation/gaming.nix`, directly after the `backgroundCpus = lib.mkOption { … };` block, add:

```nix
    backgroundUserSlices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["agents.slice"];
      description = ''
        User-manager slices confined to backgroundCpus while a game runs, the
        user-side counterpart of the nix-daemon confinement. gaming-boost runs
        as the user under gamemoded, so it sets these with systemctl --user and
        needs no polkit rule. Has no effect while backgroundCpus is null.
      '';
    };
```

- [ ] **Step 3: Extend the gaming-boost script**

Replace the `gamingBoost` definition (and its comment) at the top of the file with:

```nix
  # Toggles gaming-boost.service. gamemoded runs as a *user* service, so its
  # custom start/end hooks cannot set properties on a system unit themselves;
  # this plus the polkit rule below is the privilege bridge. User slices in
  # backgroundUserSlices are the user's own units, so it pins those directly.
  # Their failure is reported but never blocks the system-side boost.
  gamingBoost = let
    userSlices = lib.optionals (cfg.backgroundCpus != null) cfg.backgroundUserSlices;
    setUserSlices = value:
      lib.concatMapStrings (slice: ''
        systemctl --user set-property --runtime ${lib.escapeShellArgs [slice value]} ||
          echo "gaming-boost: could not set ${value} on ${slice}" >&2
      '')
      userSlices;
  in
    pkgs.writeShellApplication {
      name = "gaming-boost";
      runtimeInputs = [config.systemd.package];
      text = ''
        case "''${1:-}" in
          on)
            ${setUserSlices "AllowedCPUs=${toString cfg.backgroundCpus}"}
            exec systemctl start --no-block gaming-boost.service
            ;;
          off)
            ${setUserSlices "AllowedCPUs="}
            exec systemctl stop --no-block gaming-boost.service
            ;;
          *)
            echo "usage: gaming-boost on|off" >&2
            exit 2
            ;;
        esac
      '';
    };
```

(`toString` keeps evaluation safe when `backgroundCpus` is null; in that case `userSlices` is empty and the string is never emitted.)

- [ ] **Step 4: Set it on raider**

In `hosts/raider/configuration.nix`, directly after `backgroundCpus = "8-15";`, add:

```nix
      # Claude Code agents (home/home.nix) yield the P-cores the same way.
      backgroundUserSlices = ["agents.slice"];
```

And update the comment above `backgroundCpus` from "Confine nix-daemon to the E-cores" to "Confine nix-daemon and agents.slice to the E-cores".

- [ ] **Step 5: Verify the generated script**

Run:
```bash
nix eval --json .#nixosConfigurations.raider.config.constellation.gaming.backgroundUserSlices
grep -rl "gaming-boost" $(nix build --no-link --print-out-paths .#nixosConfigurations.raider.config.system.build.toplevel)/etc/gamemode.ini 2>/dev/null
```
Expected: `["agents.slice"]`. Then read the script that gamemode.ini's `start=` points at:
```bash
ini=$(nix build --no-link --print-out-paths .#nixosConfigurations.raider.config.system.build.toplevel)/etc/gamemode.ini
cat "$(grep '^start=' "$ini" | cut -d= -f2 | cut -d' ' -f1)"
```
Expected: the `on)` branch contains `systemctl --user set-property --runtime agents.slice AllowedCPUs=8-15`, and `off)` contains `AllowedCPUs=`. If `/etc/gamemode.ini` is not where the module writes it, locate it with `nix eval --json .#nixosConfigurations.raider.config.programs.gamemode.settings.custom`.

Confirm blackbird's script is unchanged (no `--user` lines):
```bash
nix eval --json .#nixosConfigurations.blackbird.config.constellation.gaming.backgroundUserSlices
```
Expected: `[]`.

- [ ] **Step 6: Build raider and blackbird**

Run: `just build raider && just build blackbird`
Expected: both succeed.

- [ ] **Step 7: Commit**

```bash
just fmt
git add modules/constellation/gaming.nix hosts/raider/configuration.nix
git commit -m "feat(modules): let gamemode pin background user slices to E-cores"
```

---

### Task 3: Deploy and verify on raider

**Files:** none (runtime verification).

Deploying restarts the three `claude-rc-*` units (home-manager restarts changed user services), which drops any remote-control session in progress. Interactive sessions already running keep their old cgroup until relaunched.

- [ ] **Step 1: Deploy**

Run: `just deploy raider`
Expected: activation succeeds.

- [ ] **Step 2: Slice properties**

Run: `systemctl --user show agents.slice -p CPUWeight,IOWeight,MemoryHigh`
Expected: `CPUWeight=20`, `IOWeight=20`, `MemoryHigh=12884901888`.

- [ ] **Step 3: claude-rc placement**

Run: `for s in nixos mydia job-hunting; do systemctl --user show claude-rc-$s -p ControlGroup; done`
Expected: each path contains `/agents.slice/claude-rc-<name>.service`.

- [ ] **Step 4: Interactive placement**

Run: `systemd-cgls --user-unit agents.slice --no-pager | head -20`, then start a fresh `claude --version` from a new terminal/zellij pane while it is running a session (or run `claude` in a new pane and check `cat /proc/$(pgrep -n -f 'claude-code.*/bin/claude')/cgroup`).
Expected: the new process's cgroup contains `/agents.slice/run-`.

- [ ] **Step 5: Gamemode pinning**

Run:
```bash
gamemoderun sleep 15 &
sleep 5; systemctl --user show agents.slice -p AllowedCPUs
wait; sleep 2; systemctl --user show agents.slice -p AllowedCPUs
```
Expected: `AllowedCPUs=8-15` during the run, `AllowedCPUs=` afterwards.

- [ ] **Step 6: Responsiveness under load**

With an agent build saturating the slice, compare `/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/agents.slice/cpu.pressure` (high) against `…/user@1000.service/session.slice/cpu.pressure` (`some avg10` near zero). Report both readings to the user; desktop feel is the user's call.
