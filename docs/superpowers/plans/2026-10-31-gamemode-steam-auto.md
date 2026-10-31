# Automatic GameMode for Steam Games Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Steam game activates GameMode for exactly its lifetime, with no per-game launch options.

**Architecture:** A user service, `gamemode-steam-watch`, polls every 2 seconds for Steam's `reaper SteamLaunch AppId=…` processes and registers each new one with gamemoded through its D-Bus method `RegisterGameByPID`. gamemoded's own reaper thread unregisters dead PIDs, which fires the existing `custom.end` hook. Spec: `docs/superpowers/specs/2026-10-31-gamemode-steam-auto-design.md`.

**Tech Stack:** NixOS module (`modules/constellation/gaming.nix`), `pkgs.writeShellApplication`, `busctl`, `pgrep`.

## Global Constraints

- Register through `busctl … RegisterGameByPID`, **never** `gamemoded -r <pid>`: `-r` is a toggle and ends GameMode for an already-registered PID.
- The watcher never unregisters anything; gamemoded expires dead PIDs itself (every `reaper_freq`, default 5 s).
- Poll interval: 2 seconds. Match pattern: `^reaper SteamLaunch AppId=`.
- Commit straight to `master`, conventional commits, scope `modules`. Never mention Claude.
- Run `just fmt` before committing (CI's format check fails on unformatted Nix).

---

### Task 1: The watcher service

**Files:**
- Modify: `modules/constellation/gaming.nix` — new `gamemodeSteamWatch` binding in the top `let` (after `gamingBoost`, ending at line 45); new `systemd.user.services.gamemode-steam-watch` in the `lib.mkIf config.constellation.gaming.enable` block (after the polkit rule ending at line 706); reworded comment at lines 433-437.

**Interfaces:**
- Produces: binary `gamemode-steam-watch` (no arguments, runs forever); user unit `gamemode-steam-watch.service`.

- [ ] **Step 1: Write the failing check**

Prove the unit does not exist yet:

```bash
nix eval .#nixosConfigurations.raider.config.systemd.user.services.gamemode-steam-watch.serviceConfig.ExecStart
```

Expected: FAIL, `attribute 'gamemode-steam-watch' missing`.

- [ ] **Step 2: Add the script binding**

In `modules/constellation/gaming.nix`, directly after the `gamingBoost` binding's closing `};` (line 45) and before `in {`, add:

```nix
  # Registers every Steam game with gamemoded, so GameMode needs no
  # `gamemoderun %command%` per game. Steam runs each game, native or Proton,
  # under a `reaper SteamLaunch AppId=<id>` process that lives exactly as long
  # as the game, so registering the reaper scopes GameMode to the game's
  # lifetime. gamemoded expires dead PIDs itself, which fires custom.end; this
  # never unregisters.
  #
  # RegisterGameByPID over D-Bus, not `gamemoded -r <pid>`: -r is a toggle, so
  # a watcher restarted mid-game would switch GameMode off for that game.
  # RegisterGameByPID on a known PID returns -1 and changes nothing.
  #
  # Per-process effects (renice, ioprio) land on the reaper rather than the
  # game; the system-wide ones (gaming-boost, governor, GPU level) are why
  # this exists.
  gamemodeSteamWatch = pkgs.writeShellApplication {
    name = "gamemode-steam-watch";
    runtimeInputs = [config.systemd.package pkgs.procps];
    text = ''
      declare -A seen=()
      while true; do
        unset live
        declare -A live=()
        while read -r pid; do
          live[$pid]=1
          [[ -n ''${seen[$pid]:-} ]] && continue
          if reply=$(busctl --user call com.feralinteractive.GameMode \
            /com/feralinteractive/GameMode com.feralinteractive.GameMode \
            RegisterGameByPID ii "$$" "$pid" 2>&1) && [[ $reply == "i 0" ]]; then
            seen[$pid]=1
            echo "registered Steam game reaper $pid"
          else
            echo "could not register Steam game reaper $pid: $reply" >&2
          fi
        done < <(pgrep -f '^reaper SteamLaunch AppId=' || true)
        for pid in "''${!seen[@]}"; do
          [[ -n ''${live[$pid]:-} ]] || unset "seen[$pid]"
        done
        sleep 2
      done
    '';
  };
```

`$$` is the caller PID gamemoded checks against its supervisor lists (both empty in our config); it must be a live process, and the script's own shell is.

- [ ] **Step 3: Add the user service**

In the `(lib.mkIf config.constellation.gaming.enable { … })` block, directly after the `security.polkit.extraConfig = …;` statement (ends line 706), add:

```nix
      systemd.user.services.gamemode-steam-watch = {
        description = "Register Steam games with GameMode";
        wantedBy = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        after = ["graphical-session.target"];
        serviceConfig = {
          ExecStart = lib.getExe gamemodeSteamWatch;
          Restart = "on-failure";
        };
      };
```

Not gated on `cfg.gamingMode`: GameMode itself is on wherever `constellation.gaming` is, and the governor/GPU effects apply without gaming-boost.

- [ ] **Step 4: Reword the stale hook comment**

Replace lines 433-437:

```nix
                # Ride gamemode's own lifecycle rather than a manual toggle. These
                # fire for anything launched via gamemoderun — Lutris/Heroic/Bottles
                # do that by default, bare Steam needs `gamemoderun %command%` in
                # the launch options. That is the same gate which already governs
                # gpu.amd_performance_level above, so it is not a new limitation.
```

with:

```nix
                # Ride gamemode's own lifecycle rather than a manual toggle. These
                # fire for every registered game: Steam games via
                # gamemode-steam-watch, Lutris via gamemoderun by default, Heroic
                # when its GameMode setting is on.
```

- [ ] **Step 5: Format and run the check again**

```bash
just fmt
nix eval .#nixosConfigurations.raider.config.systemd.user.services.gamemode-steam-watch.serviceConfig.ExecStart
```

Expected: PASS, a store path ending in `/bin/gamemode-steam-watch`.

- [ ] **Step 6: Build the script and test it against the live gamemoded**

Build only the watcher (fast, and the writeShellApplication shellcheck runs here):

```bash
nix build --no-link '.#nixosConfigurations.raider.config.systemd.user.units."gamemode-steam-watch.service".unit'
watch=$(nix eval --raw .#nixosConfigurations.raider.config.systemd.user.services.gamemode-steam-watch.serviceConfig.ExecStart)
ls -l "$watch"
```

Expected: the build passes (writeShellApplication runs shellcheck), and `ls` shows the script exists.

Start a fake reaper, run the watcher, and confirm registration. This briefly activates GameMode (and gaming-boost) on raider, which is harmless:

```bash
bash -c 'exec -a "reaper SteamLaunch AppId=0 --" sleep 60' & fake=$!
"$watch" & w=$!
sleep 4
gamemoded -s "$fake"
```

Expected: `gamemode is active and [<fake pid>] registered`, and the watcher printed `registered Steam game reaper <fake pid>` once.

Restart safety (the toggle bug this design avoids): kill the watcher and start it again while the fake reaper lives:

```bash
kill "$w"; "$watch" & w=$!
sleep 4
gamemoded -s "$fake"
```

Expected: still `active and [<fake pid>] registered`; the new watcher logs one `could not register … i -1` line, not a deregistration.

Expiry: end the fake game and wait out gamemoded's reaper:

```bash
kill "$fake"; sleep 7
gamemoded -s
kill "$w"
```

Expected: `gamemode is inactive`.

- [ ] **Step 7: Build the full host**

```bash
just build raider
```

Expected: success.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/gaming.nix
git commit -m "feat(modules): activate gamemode automatically for Steam games"
```

---

### Task 2: Deploy and verify with a real game

**Files:** none.

**Interfaces:**
- Consumes: `gamemode-steam-watch.service` from Task 1.

Deploying is outward-facing: confirm with the user before running it.

- [ ] **Step 1: Deploy raider**

```bash
just deploy raider
```

Expected: activation succeeds.

- [ ] **Step 2: Service is running**

```bash
systemctl --user status gamemode-steam-watch --no-pager
```

Expected: `active (running)`. If it is inactive, the session target was already up before the unit was installed. Start it once with `systemctl --user start gamemode-steam-watch`; later logins start it automatically.

- [ ] **Step 3: Real game (user launches one from Steam with no launch options)**

```bash
gamemoded -s
systemctl is-active gaming-boost
journalctl --user -u gamemode-steam-watch -n 5 --no-pager
```

Expected: `gamemode is active`, `active`, and a `registered Steam game reaper <pid>` line.

- [ ] **Step 4: Quit the game**

Wait ~7 s, then:

```bash
gamemoded -s
systemctl is-active gaming-boost
```

Expected: `gamemode is inactive`, `inactive`.

blackbird picks the change up on its next deploy; nothing host-specific is needed.
