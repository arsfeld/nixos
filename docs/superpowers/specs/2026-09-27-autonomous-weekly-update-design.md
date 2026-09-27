# Autonomous Weekly Flake Update & Healing Agent

## Problem

The weekly update and deploy pipeline—previously split between GitHub Actions (`.github/workflows/update.yml`) and galactica's timer (`hosts/galactica/weekly-deploy.nix`)—has never completed end-to-end.

Three fundamental issues broke the previous design:
1. **Rigid automation vs. dynamic breaking changes:** A simple `nix flake update` script inevitably fails whenever nixpkgs marks a package insecure (e.g., `radicle-node-1.10.3` on 2026-09-27), deprecates options, or changes module interfaces. A dumb script cannot diagnose or heal these issues, leaving the update permanently stranded.
2. **Brittle cross-system handoffs & GITHUB_TOKEN traps:** Pushes made by GitHub Actions bots do not trigger downstream CI workflows by default. Mitigations (like explicit `workflow_dispatch` calls) introduced complex timing races between GitHub runner schedules and galactica's deploy timer.
3. **Egress & alerting blocks:** GitHub-hosted runners encounter Cloudflare managed challenges (HTTP 403) when attempting to reach `ntfy.arsfeld.one`, blinding operators to workflow failures until weeks later.

## Solution Overview

We replace both GitHub Actions `update.yml` and galactica's `weekly-deploy.nix` with a single, unified, autonomous update agent hosted directly on **raider** (`hosts/raider`).

Raider is the designated fleet deploy driver: it already holds `NIKS3_AUTH_TOKEN_FILE`, has fast local build hardware, has direct Tailscale access to all hosts, and has the Antigravity CLI (`agy`) installed and authenticated.

The new architecture follows a **Hybrid Runner with Targeted AI Healing**:
- **Deterministic outer loop:** A shell runner script handles workspace setup, git synchronization, `nix flake update`, build verification, deployment, and alerting.
- **Targeted AI Healing (`agy`):** If `nix flake update` results in build or evaluation breakage, the runner invokes `agy` in non-interactive print mode (`agy --print --dangerously-skip-permissions`). The agent diagnoses the error, edits the Nix configuration in the isolated workspace (e.g. updating `permittedInsecurePackages`, updating renamed options, or patching configs), and verifies the fix.
- **Hard Verification Gate:** The runner independently tests the build before committing or pushing. Broken code is never pushed to `origin/master`.
- **Direct Deployment & Dual Alerts:** Clean updates are committed, pushed to `origin/master`, deployed to tier-1 (`just deploy @tier1`), and reported via both **ntfy** and **email**.

---

## Architecture & Components

```
+-----------------------------------------------------------------------------------+
| Raider (Workstation & Deploy Driver)                                              |
|                                                                                   |
|  [systemd.timers.weekly-update] -> [systemd.services.weekly-update] / [just]      |
|                                         |                                         |
|                                         v                                         |
|                     +---------------------------------------+                     |
|                     | Supervisor Script (weekly-update)     |                     |
|                     +---------------------------------------+                     |
|                                         |                                         |
|                 +-----------------------+-----------------------+                 |
|                 | (1. Sync & Update)                            |                 |
|                 v                                               |                 |
|     +-----------------------+                                   |                 |
|     | Isolated Workspace    |                                   |                 |
|     | ~/.local/share/       |                                   |                 |
|     | nixos-weekly-update   |                                   |                 |
|     +-----------------------+                                   |                 |
|                 |                                               |                 |
|                 | 2. nix flake update                           |                 |
|                 | 3. just dry-run @tier1                        |                 |
|                 v                                               |                 |
|            +---------+  Pass                                    |                 |
|            | Passes? |-----------------------------+            |                 |
|            +---------+                             |            |                 |
|                 | Fail                             |            |                 |
|                 v                                  |            |                 |
|     +-----------------------+                      |            |                 |
|     | AI Healing (agy)      |                      |            |                 |
|     | - Diagnose failure    |                      |            |                 |
|     | - Edit Nix configs    |                      |            |                 |
|     | - Self-verify         |                      |            |                 |
|     +-----------------------+                      |            |                 |
|                 |                                  |            |                 |
|                 v                                  |            |                 |
|      [Hard Verification Gate]                      |            |                 |
|      (just dry-run @tier1)                         |            |                 |
|            |         |                             |            |                 |
|       Pass |         | Still Fails                 |            |                 |
|            v         v                             |            |                 |
|            |    [Abort & Revert]                   |            |                 |
|            |    [Send Alert Mail/Ntfy]             |            |                 |
|            |                                       |            |                 |
|            +-------------------+-------------------+            |                 |
|                                |                                |                 |
|                                v                                |                 |
|                 +-----------------------------+                 |                 |
|                 | 4. git commit & push master |                 |                 |
|                 +-----------------------------+                 |                 |
|                                |                                |                 |
|                                v                                |                 |
|                 +-----------------------------+                 |                 |
|                 | 5. just deploy @tier1       |                 |                 |
|                 |    (phase 1: niks3 push)    |                 |                 |
|                 |    (phase 2: switch)        |                 |                 |
|                 +-----------------------------+                 |                 |
|                                |                                |                 |
|                                v                                v                 |
|                 +-----------------------------------------------+                 |
|                 | 6. Notifications (ntfy + email)               |                 |
|                 +-----------------------------------------------+                 |
+-----------------------------------------------------------------------------------+
```

### 1. Host Placement & Service Configuration

Implemented as a NixOS service on `raider` in `hosts/raider/weekly-update.nix`:

- **`systemd.services.weekly-update`**:
  - `serviceConfig.User = "arosenfeld"`
  - `serviceConfig.Group = "users"`
  - `environment.HOME = "/home/arosenfeld"`
  - `environment.NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path`
  - Runs with access to the user's nix-profile tools (`agy`, `just`, `git`, `nix`), ssh-agent / git SSH credentials, and Tailscale connection.
- **`systemd.timers.weekly-update`**:
  - `timerConfig.OnCalendar = "Sun *-*-* 03:00:00"` (local time)
  - `timerConfig.Persistent = true`: If raider is suspended or shut down at 03:00, the unit triggers shortly after wake/boot.
- **Manual Trigger**:
  - Added to `justfile`: `just auto-update` (invoking the update script directly or triggering `sudo systemctl start weekly-update`).

### 2. Workspace Isolation

To ensure that scheduled runs never touch, dirty, or conflict with uncommitted local work on raider:
- The supervisor runs exclusively in a dedicated directory: `/home/arosenfeld/.local/share/nixos-weekly-update/nixos`.
- Your primary development directory at `/home/arosenfeld/Code/nixos` is completely untouched.
- At the start of every run:
  ```bash
  if [ ! -d "$WORKSPACE/.git" ]; then
    git clone git@github.com:arsfeld/nixos.git "$WORKSPACE"
  fi
  cd "$WORKSPACE"
  git fetch origin master
  git checkout master
  git reset --hard origin/master
  git clean -fd
  ```

---

## Detailed Execution Flow

### Phase 1: Flake Update & Fast Path Check
1. The supervisor executes `nix flake update` in the isolated workspace.
2. Checks if `flake.lock` changed via `git diff --quiet flake.lock`.
   - If no inputs changed: Logs that dependencies are up to date, sends no notifications (or low-priority debug log), and exits 0.
3. Fast Path Verification:
   - Runs `just dry-run @tier1` (or `nix-fast-build --flake .#deployTargets`).
   - If the dry-run/build succeeds (exit code 0):
     - Skip AI healing completely (0 tokens consumed).
     - Commit `flake.lock`:
       ```bash
       git commit -am "chore: update flake inputs"
       ```
     - Proceed directly to Phase 3 (Push & Deploy).

### Phase 2: AI Healing Loop (`agy`)
If `just dry-run @tier1` fails with non-zero exit code:
1. Capture error log to `/tmp/weekly-update-error.log`.
2. Launch `agy` non-interactively:
   ```bash
   agy --print \
       --dangerously-skip-permissions \
       --effort high \
       --print-timeout 15m \
       "You are an automated maintenance agent for this NixOS flake repository.
We ran 'nix flake update', but tier-1 verification failed with the following error:

$(cat /tmp/weekly-update-error.log)

Your task:
1. Investigate and diagnose the root cause of the evaluation or build failure.
2. Modify the Nix configuration in this repository to resolve the issue (for example: adding an insecure package to nixpkgs.config.permittedInsecurePackages, updating renamed module options, or patching obsolete configurations).
3. Test your changes by running 'just dry-run @tier1'.
4. Ensure 'git status' and 'git diff' contain only necessary, clean changes.
5. Conclude your final response with a concise 1-2 paragraph summary of what failed and how you resolved it."
   ```
3. **Hard Verification Gate:**
   - When `agy` exits, the supervisor independently re-executes `just dry-run @tier1`.
   - **Verification Pass:**
     - The supervisor generates a commit containing `flake.lock` and all configuration fixes:
       ```bash
       git commit -am "chore: update flake inputs and heal build breakage

       [Healed by agy]
       $(cat /tmp/agy-summary.txt)"
       ```
     - Proceeds to Phase 3.
   - **Verification Failure / Timeout:**
     - The supervisor resets the workspace (`git reset --hard origin/master` and `git clean -fd`).
     - Saves `/tmp/weekly-update-error.log` and the `agy` transcript to `/home/arosenfeld/.local/share/nixos-weekly-update/logs/`.
     - Sends failure alert via ntfy and email.
     - Exits 1. Broken commits are never pushed.

### Phase 3: Push, Deploy & Post-Deploy Health Check
1. **Push:**
   - Supervisor runs `git pull --rebase origin master && git push origin master`.
2. **Deploy:**
   - Supervisor executes:
     ```bash
     just deploy @tier1
     ```
   - Phase 1: builds all closures locally or via remote builders, pushes closures to `niks3.arsfeld.dev`.
   - Phase 2: activates `basestar`, `galactica`, and `raider`.
3. **Post-Deploy Health Check:**
   - Runs failed unit check across tier-1 hosts:
     ```bash
     for host in basestar galactica raider; do
       ssh root@$host.bat-boa.ts.net "systemctl --failed --no-legend"
     done
     ```
   - If any core services failed, records the warning in the report.

### Phase 4: Notifications (ntfy + Email)
The supervisor dispatches notifications via both established channels:

1. **ntfy Notification:**
   - Invokes `config.constellation.backupNotify.script`:
     - On Success:
       - Title: `Weekly Update: tier-1 deployed successfully`
       - Body: Details whether it was a clean update or healed by `agy`, which packages changed, and confirmation of host activations.
     - On Failure:
       - Title: `ACTION NEEDED: Weekly update failed on raider`
       - Body: Indicates failing stage (build, heal, or deploy) and log path.

2. **Email Notification:**
   - Invokes `${pkgs.send-email-event}/bin/send-email-event`:
     - From: `admin@rosenfeld.one`
     - To: `alex@rosenfeld.one`
     - Subject: `Weekly Update Report: <Status>`
     - Body: Full details including git commit SHA, `agy` healing summary (if triggered), deploy status per host, and health check output.

---

## Decommissioning Legacy Infrastructure

1. **Remove GitHub Actions Workflow:**
   - Delete `.github/workflows/update.yml`.
   - Eliminates `GITHUB_TOKEN` triggering problems, runner timeout issues, and Cloudflare 403 blocks.
2. **Remove Galactica Deploy Unit:**
   - Remove `./weekly-deploy.nix` import from `hosts/galactica/configuration.nix`.
   - Delete `hosts/galactica/weekly-deploy.nix`.
   - Remove `docs/superpowers/specs/2026-09-24-weekly-update-handoff-design.md` (superseded by this design).
3. **Documentation Updates:**
   - Update `CLAUDE.md` "Weekly Automation" section to reflect the new raider-based autonomous agent, its timer, and `just auto-update`.

---

## Verification & Rollout Plan

1. **Local Dry-Run / Test:**
   - Implement `hosts/raider/weekly-update.nix` and runner script.
   - Run the script manually via `just auto-update`.
   - Verify that:
     1. Isolated workspace clones and updates cleanly.
     2. Build verification properly catches known issues (e.g. testing with `radicle-node` insecure package).
     3. `agy` triggers, applies the fix, and independently passes the verification gate.
     4. `just deploy @tier1` activates cleanly across `basestar`, `galactica`, and `raider`.
     5. Notification emails arrive at `alex@rosenfeld.one` and ntfy alerts arrive at `ntfy.arsfeld.one/backups`.
2. **Commit & Install:**
   - Commit all changes to master and push.
   - Deploy to `raider` and `galactica` (`just deploy raider galactica`).
   - Confirm `systemctl --user status weekly-update.timer` (or system timer) is active on raider.
