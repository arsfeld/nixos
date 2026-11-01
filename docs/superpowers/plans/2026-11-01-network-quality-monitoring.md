# Network Quality Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home Assistant on galactica records the mesh latency to raider, the
internet latency, and internet throughput, and keeps their history.

**Architecture:** Nix installs the `speedtestdotnet` component and declares an
automation that runs a speed test every 4 hours. The Ping and Speedtest.net
integrations can only be set up through HA's UI (config flow), so those entries
are a one-time manual step. The module documents that step.

**Tech Stack:** NixOS `services.home-assistant` on galactica; HA integrations
`ping` and `speedtestdotnet`.

Spec: `docs/superpowers/specs/2026-11-01-network-quality-monitoring-design.md`

## Global Constraints

- Every change goes in `modules/hosts/galactica/services/home-assistant.nix`.
  Do not create a new file.
- Commit straight to `master`. No branches, no worktrees.
- Commit format: `<type>(galactica): <subject>`. Never mention Claude.
- Speed test schedule: every 4 hours, `time_pattern` `hours = "/4"`.
- The automation key is `"automation network"`. The entity it updates is
  `sensor.speedtest_download`.
- Ping targets: `raider.local`, `basestar.bat-boa.ts.net`, `1.1.1.1`, each
  with a count of 5.
- Run `just fmt` before committing. CI rejects unformatted Nix.
- Evaluate and build only galactica, one at a time. Never evaluate cylon-link.

---

### Task 1: Install speedtestdotnet and schedule it in Nix

**Files:**
- Modify: `modules/hosts/galactica/services/home-assistant.nix`
  - the `extraComponents` list, after the `"ping"` entry (line 65)
  - the header comment block (lines 1-24)
  - the `config` attrset, before the `"automation ui"` include (line 171)

**Interfaces:**
- Produces: `services.home-assistant.config."automation network"`, a list
  holding one automation whose alias is `"Network - Speedtest"`.
  `extraComponents` contains `"speedtestdotnet"`.

- [ ] **Step 1: Check the current state (this is the failing test)**

Run:
```bash
nix eval --json .#nixosConfigurations.galactica.config.services.home-assistant.config --apply 'c: c ? "automation network"'
nix eval --json .#nixosConfigurations.galactica.config.services.home-assistant.extraComponents --apply 'l: builtins.elem "speedtestdotnet" l'
```
Expected: `false` and `false`.

- [ ] **Step 2: Add the component**

In `extraComponents`, directly after
`"ping" # Ping (ICMP) network presence detection`, add:

```nix
          "speedtestdotnet" # Internet speed; polled only by "automation network"
```

- [ ] **Step 3: Add the automation**

In the `config` attrset, directly above the
`# Allow UI-managed configuration files` comment, add:

```nix
          # Network quality history: mesh latency to raider, internet latency,
          # internet throughput. Design:
          # docs/superpowers/specs/2026-11-01-network-quality-monitoring-design.md
          #
          # Ping and Speedtest.net are config-flow only, so their entries are
          # added once in the UI (Settings → Devices & services → Add):
          #   Ping  raider.local             mesh latency over the LAN. Not the
          #                                  Tailscale name: that measures the
          #                                  tunnel, not the Deco mesh.
          #   Ping  basestar.bat-boa.ts.net  internet path. basestar's public
          #                                  IP drops ICMP echo (OCI list allows
          #                                  type 3 only).
          #   Ping  1.1.1.1                  neutral reference. If basestar
          #                                  rises and this doesn't, the cause is
          #                                  Tailscale/DERP, not the fiber.
          #   (count 5 each)
          #   Speedtest.net, then System options → disable "Enable polling for
          #   updates", so only the automation below runs tests (its default is
          #   hourly, ~24 full-bandwidth tests a day).
          #
          # Updating one speedtest entity refreshes the integration's
          # coordinator, so download, upload and ping all update. The entity
          # ID comes from the UI-created entry: renaming it breaks this.
          "automation network" = [
            {
              alias = "Network - Speedtest";
              description = "Run an internet speed test every 4 hours";
              triggers = [
                {
                  trigger = "time_pattern";
                  hours = "/4";
                }
              ];
              actions = [
                {
                  action = "homeassistant.update_entity";
                  target.entity_id = "sensor.speedtest_download";
                }
              ];
              mode = "single";
            }
          ];
```

- [ ] **Step 4: Update the header comment**

In the header's `# Key features:` list, after the line
`# - Heating automations live in ./home-assistant-heating/`, add:

```nix
# - Network quality history (ping + Speedtest.net); see "automation network"
```

- [ ] **Step 5: Run the eval checks again**

Run the two commands from Step 1.
Expected: `true` and `true`.

Then check the automation's shape:
```bash
nix eval --json '.#nixosConfigurations.galactica.config.services.home-assistant.config."automation network"'
```
Expected: a one-element list with `"alias":"Network - Speedtest"`,
`"hours":"/4"` and `"entity_id":"sensor.speedtest_download"`.

- [ ] **Step 6: Format and build**

```bash
just fmt
nice just build galactica
```
Expected: the build succeeds. If it fails with an unknown component,
`speedtestdotnet` is missing from the HA package's component list. Stop and
report it; do not work around it.

- [ ] **Step 7: Commit**

```bash
git add modules/hosts/galactica/services/home-assistant.nix
git commit -m "feat(galactica): network quality history in home assistant" -- modules/hosts/galactica/services/home-assistant.nix
```

---

### Task 2: Deploy, set up the UI entries, verify

This task needs a person: the integrations can only be added in HA's UI. The
executing agent deploys and checks the result. The user adds the entries.

**Files:** none.

**Interfaces:**
- Consumes: Task 1's commit on `master`.

- [ ] **Step 1: Push and deploy galactica (from raider)**

```bash
git push -u origin master
just deploy galactica
```
Expected: activation succeeds. `ssh galactica.bat-boa.ts.net systemctl is-active home-assistant`
prints `active`.

- [ ] **Step 2: Check that HA loaded the automation**

```bash
ssh galactica.bat-boa.ts.net "journalctl -u home-assistant --since '-10 min' | grep -iE 'speedtest|automation network|Invalid config'"
```
Expected: no `Invalid config` line mentioning `automation network`.

- [ ] **Step 3: Hand off to the user for UI setup**

Ask the user to add the entries listed in the Nix comment: three Ping entries
(`raider.local`, `basestar.bat-boa.ts.net`, `1.1.1.1`, count 5) and
Speedtest.net with polling disabled. Then ask them to confirm the speed test
entity is `sensor.speedtest_download`, or to rename it to that.

- [ ] **Step 4: Verify after setup**

Ask the user to run the automation by hand ("Network - Speedtest" → Run
actions). Then check that the following entities have numeric states
(Developer tools → States, filter `speedtest` and `ping`):
- download, upload and ping from speedtest
- a round-trip-average sensor for each ping target

Expected: all of them are numeric. raider's sensor reads `unavailable` only if
raider is asleep.

- [ ] **Step 5: Dashboard (UI, optional)**

Add one view with three cards:
- a history graph of the three ping average sensors
- a statistics graph (mean) of speedtest download and upload
- the Deco node entities

No commit: dashboards are UI-managed on this host.
