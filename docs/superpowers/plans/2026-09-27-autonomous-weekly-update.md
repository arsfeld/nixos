# Autonomous Weekly Update & Healing Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an autonomous weekly flake update, build-breakage healing, and tier-1 deployment agent on `raider` using `agy`, replacing the broken GitHub Actions and galactica deploy pipelines.

**Architecture:** A supervisor shell script drives a deterministic lifecycle (workspace setup, `nix flake update`, verification, deploy, dual ntfy/email notifications) in an isolated workspace (`~/.local/share/nixos-weekly-update/nixos`). If build/eval breakage occurs, it invokes `agy` in non-interactive print mode with a high reasoning effort to diagnose and heal the Nix configurations before an independent verification gate. Scheduled via systemd timer on raider with `Persistent = true` and exposed via `just auto-update`.

**Tech Stack:** NixOS, systemd, bash, Antigravity CLI (`agy`), `just`, `nix-fast-build`, `send-email-event` (Python/msmtp), ntfy (`backupNotify`).

**Spec:** [`docs/superpowers/specs/2026-09-27-autonomous-weekly-update-design.md`](file:///home/arosenfeld/Code/nixos/docs/superpowers/specs/2026-09-27-autonomous-weekly-update-design.md)

## Global Constraints

- Must run on `raider` as user `arosenfeld` with `HOME=/home/arosenfeld` and `$NIKS3_AUTH_TOKEN_FILE` set.
- Must operate exclusively inside isolated workspace `/home/arosenfeld/.local/share/nixos-weekly-update/nixos`; never touch `~/Code/nixos`.
- Must never push broken commits or untested closures to `origin/master`.
- AI healing (`agy`) must pass an independent verification gate (`just dry-run @tier1`) before any commit or push.
- Must alert on both channels: ntfy (`https://ntfy.arsfeld.one/backups`) and email (`admin@rosenfeld.one` -> `alex@rosenfeld.one`).
- Must decommission `.github/workflows/update.yml` and `hosts/galactica/weekly-deploy.nix`.

---

### Task 1: Create `hosts/raider/weekly-update.nix`

**Files:**
- Create: `hosts/raider/weekly-update.nix`

**Interfaces:**
- Consumes:
  - `config.sops.secrets."niks3-api-token".path`
  - `config.constellation.backupNotify.script`
  - `config.constellation.email.fromEmail`
  - `config.constellation.email.toEmail`
  - `pkgs.send-email-event`
- Produces:
  - `systemd.services.weekly-update`
  - `systemd.timers.weekly-update`
  - Package `weekly-update` installed in system profile

- [ ] **Step 1: Write `hosts/raider/weekly-update.nix`**

Create `hosts/raider/weekly-update.nix` with the complete supervisor script, systemd service, and timer:

```nix
# Autonomous weekly flake update and AI healing agent for raider
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.weeklyUpdate;
  
  weeklyUpdateScript = pkgs.writeShellScriptBin "weekly-update" ''
    set -euo pipefail

    export PATH="${makeBinPath [
      pkgs.git
      pkgs.nix
      pkgs.just
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.curl
      pkgs.systemd
    ]}:/home/arosenfeld/.nix-profile/bin:/home/arosenfeld/.local/share/gemini/bin:$PATH"

    WORKSPACE="${cfg.workspaceDir}"
    STATE_DIR="${cfg.stateDir}"
    LOG_DIR="$STATE_DIR/logs"
    mkdir -p "$LOG_DIR" "$(dirname "$WORKSPACE")"

    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    RUN_LOG="$LOG_DIR/run_$TIMESTAMP.log"
    ERROR_LOG="$LOG_DIR/error_$TIMESTAMP.log"
    HEAL_LOG="$LOG_DIR/heal_$TIMESTAMP.log"
    exec > >(tee -a "$RUN_LOG") 2>&1

    echo "=== Starting Weekly Update: $(date) ==="

    notify_all() {
      local status="$1"
      local title="$2"
      local body="$3"

      echo "--> Sending ntfy alert: $title"
      if [ -f "${config.constellation.backupNotify.envFile}" ]; then
        set +u
        # shellcheck disable=SC1090
        . "${config.constellation.backupNotify.envFile}"
        set -u
        ${config.constellation.backupNotify.script} "$title" "$body" || true
      fi

      echo "--> Sending email alert: $title"
      ${pkgs.send-email-event}/bin/send-email-event \
        "$title" \
        "$body" \
        --email-from "${config.constellation.email.fromEmail}" \
        --email-to "${config.constellation.email.toEmail}" || true
    }

    on_failure() {
      local line="$1"
      local cmd="$2"
      echo "ERROR: Failed at line $line command '$cmd'"
      if [ -d "$WORKSPACE/.git" ]; then
        cd "$WORKSPACE"
        git reset --hard origin/master || true
        git clean -fd || true
      fi
      local err_summary="Weekly update failed during execution at line $line ($cmd). See log: $RUN_LOG"
      if [ -s "$ERROR_LOG" ]; then
        err_summary="$err_summary"$'\n\n'"Build error:"$'\n'"$(head -n 25 "$ERROR_LOG")"
      fi
      notify_all "failure" "ACTION NEEDED: Weekly update failed on raider" "$err_summary"
      exit 1
    }
    trap 'on_failure $LINENO "$BASH_COMMAND"' ERR

    # 1. Sync isolated workspace
    echo "--> Syncing workspace at $WORKSPACE"
    if [ ! -d "$WORKSPACE/.git" ]; then
      git clone git@github.com:arsfeld/nixos.git "$WORKSPACE"
    fi
    cd "$WORKSPACE"
    git fetch origin master
    git checkout master
    git reset --hard origin/master
    git clean -fd

    INITIAL_SHA="$(git rev-parse HEAD)"

    # 2. Update flake inputs
    echo "--> Updating flake inputs"
    nix flake update

    if git diff --quiet flake.lock; then
      echo "--> flake.lock is already up to date. Nothing to do."
      exit 0
    fi

    # 3. Verification & AI Healing Loop
    echo "--> Testing tier-1 builds (dry-run)"
    HEALED=false
    HEAL_SUMMARY=""

    if ! just dry-run @tier1 >"$ERROR_LOG" 2>&1; then
      echo "--> Build/eval failed! Launching AI healing agent (agy)..."
      cat "$ERROR_LOG"

      PROMPT="You are an automated maintenance agent for this NixOS flake repository.
We ran 'nix flake update', but 'just dry-run @tier1' failed with the following error:

$(cat "$ERROR_LOG")

Your task:
1. Investigate and diagnose the root cause of the evaluation or build failure.
2. Modify the Nix configuration in this repository to resolve the issue (for example: adding an insecure package to nixpkgs.config.permittedInsecurePackages, updating renamed module options, or patching obsolete configurations).
3. Test your changes by running 'just dry-run @tier1'.
4. Ensure 'git status' and 'git diff' contain only necessary, clean changes.
5. Conclude your final response with a concise 1-2 paragraph summary of what failed and how you resolved it."

      if ! agy --print \
               --dangerously-skip-permissions \
               --effort high \
               --print-timeout 15m \
               "$PROMPT" >"$HEAL_LOG" 2>&1; then
        echo "--> agy healing command failed or timed out."
        cat "$HEAL_LOG"
        exit 1
      fi

      echo "--> agy completed. Running independent verification gate..."
      if ! just dry-run @tier1 >"$ERROR_LOG" 2>&1; then
        echo "--> Independent verification failed after AI healing attempt."
        cat "$ERROR_LOG"
        exit 1
      fi

      HEALED=true
      HEAL_SUMMARY="$(tail -n 20 "$HEAL_LOG")"
      echo "--> Independent verification PASSED after AI healing!"
    fi

    # 4. Commit and push
    echo "--> Committing changes"
    git add -A
    if [ "$HEALED" = true ]; then
      COMMIT_MSG=$(cat <<EOF
chore: update flake inputs and heal build breakage

[Healed by agy]
$HEAL_SUMMARY
EOF
)
      git commit -m "$COMMIT_MSG"
    else
      git commit -m "chore: update flake inputs"
    fi

    echo "--> Pushing to origin/master"
    git pull --rebase origin master
    git push origin master

    NEW_SHA="$(git rev-parse HEAD)"

    # 5. Deploy to tier-1
    echo "--> Deploying to tier-1 hosts"
    just deploy @tier1

    # 6. Post-deploy health checks
    echo "--> Running post-deploy health checks"
    FAILED_SERVICES=""
    for host in basestar galactica raider; do
      echo "Checking failed units on $host..."
      if [ "$host" = "raider" ]; then
        HOST_FAILED="$(systemctl --failed --no-legend || true)"
      else
        HOST_FAILED="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$host.bat-boa.ts.net" "systemctl --failed --no-legend" || true)"
      fi
      if [ -n "$HOST_FAILED" ]; then
        FAILED_SERVICES="$FAILED_SERVICES"$'\n'"[$host]"$'\n'"$HOST_FAILED"
      fi
    done

    # 7. Success notification
    SUCCESS_BODY="Weekly update successfully completed from $INITIAL_SHA to $NEW_SHA."$'\n\n'
    if [ "$HEALED" = true ]; then
      SUCCESS_BODY="$SUCCESS_BODY"$'\n'"Build breakage was auto-healed by agy:"$'\n'"$HEAL_SUMMARY"$'\n\n'
    fi
    if [ -n "$FAILED_SERVICES" ]; then
      SUCCESS_BODY="$SUCCESS_BODY"$'\n'"Warning: Post-deploy health check detected failed units:"$'\n'"$FAILED_SERVICES"
      notify_all "warning" "Weekly Update: tier-1 deployed with service warnings" "$SUCCESS_BODY"
    else
      SUCCESS_BODY="$SUCCESS_BODY"$'\n'"All tier-1 hosts (basestar, galactica, raider) healthy."
      notify_all "success" "Weekly Update: tier-1 deployed successfully" "$SUCCESS_BODY"
    fi

    echo "=== Weekly Update finished successfully: $(date) ==="
  '';
in {
  options.services.weeklyUpdate = {
    enable = mkEnableOption "autonomous weekly update and healing service";

    workspaceDir = mkOption {
      type = types.str;
      default = "/home/arosenfeld/.local/share/nixos-weekly-update/nixos";
      description = "Dedicated isolated workspace directory for weekly updates.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/home/arosenfeld/.local/share/nixos-weekly-update";
      description = "Directory for weekly update logs and state.";
    };

    calendar = mkOption {
      type = types.str;
      default = "Sun *-*-* 03:00:00";
      description = "Systemd OnCalendar expression for weekly updates.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      weeklyUpdateScript
    ];

    systemd.services.weekly-update = {
      description = "Autonomous weekly flake update, healing and tier-1 deployment";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = [
        pkgs.git
        pkgs.nix
        pkgs.just
        pkgs.openssh
        pkgs.coreutils
        pkgs.gnused
        pkgs.gnugrep
        pkgs.jq
        pkgs.curl
        pkgs.systemd
      ];

      environment = {
        HOME = "/home/arosenfeld";
        NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "arosenfeld";
        Group = "users";
        ExecStart = "${weeklyUpdateScript}/bin/weekly-update";
        TimeoutSec = "3h";
      };
    };

    systemd.timers.weekly-update = {
      description = "Timer for autonomous weekly update";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.calendar;
        Persistent = true;
      };
    };
  };
}
```

- [ ] **Step 2: Syntax check the new module**

Run: `nix-instantiate --parse hosts/raider/weekly-update.nix`
Expected: Expression parses successfully.

- [ ] **Step 3: Commit**

```bash
git add hosts/raider/weekly-update.nix
git commit -m "feat(raider): add weekly-update autonomous agent module"
```

---

### Task 2: Enable in `hosts/raider/configuration.nix` & Add `just auto-update`

**Files:**
- Modify: `hosts/raider/configuration.nix:1-60`
- Modify: `justfile:7-15`

**Interfaces:**
- Consumes: `services.weeklyUpdate` from `hosts/raider/weekly-update.nix`
- Produces: `just auto-update` command and enabled `weekly-update` service/timer on `raider`

- [ ] **Step 1: Import and enable `weekly-update.nix` in `hosts/raider/configuration.nix`**

In `hosts/raider/configuration.nix`, add `./weekly-update.nix` to imports, and enable `services.weeklyUpdate = { enable = true; };`.

```nix
  imports = [
    ./hardware-configuration.nix
    ./services
    ./backup
    ./monitoring.nix
    ./pantheon.nix
    ./weekly-update.nix
  ];

  services.weeklyUpdate.enable = true;
```

- [ ] **Step 2: Add `auto-update` recipe to `justfile`**

In `justfile`, add:

```just
# Run the autonomous weekly flake update, healing, and tier-1 deployment
auto-update:
    systemctl start weekly-update.service || weekly-update
```

- [ ] **Step 3: Test evaluation on raider**

Run: `nix eval .#nixosConfigurations.raider.config.services.weeklyUpdate.enable`
Expected: `true`

Run: `nix eval .#nixosConfigurations.raider.config.systemd.services.weekly-update.description`
Expected: `"Autonomous weekly flake update, healing and tier-1 deployment"`

- [ ] **Step 4: Commit**

```bash
git add hosts/raider/configuration.nix justfile
git commit -m "feat(raider): enable weeklyUpdate service and add just auto-update recipe"
```

---

### Task 3: Decommission `.github/workflows/update.yml` & `hosts/galactica/weekly-deploy.nix`

**Files:**
- Delete: `.github/workflows/update.yml`
- Delete: `hosts/galactica/weekly-deploy.nix`
- Modify: `hosts/galactica/configuration.nix:15-30`

**Interfaces:**
- Consumes: None
- Produces: Clean removal of obsolete weekly automation units on galactica and GitHub

- [ ] **Step 1: Remove `weekly-deploy.nix` import from `hosts/galactica/configuration.nix`**

In `hosts/galactica/configuration.nix`, remove the `./weekly-deploy.nix` line from imports.

- [ ] **Step 2: Delete `hosts/galactica/weekly-deploy.nix` and `.github/workflows/update.yml`**

```bash
git rm hosts/galactica/weekly-deploy.nix .github/workflows/update.yml
```

- [ ] **Step 3: Verify galactica configuration evaluates cleanly**

Run: `nix eval .#nixosConfigurations.galactica.config.systemd.services.weekly-deploy.enable 2>/dev/null || echo "removed"`
Expected: `"removed"`

- [ ] **Step 4: Commit**

```bash
git add hosts/galactica/configuration.nix
git commit -m "refactor: decommission GitHub update.yml and galactica weekly-deploy"
```

---

### Task 4: Update Documentation in `CLAUDE.md` and Archive Legacy Spec

**Files:**
- Modify: `CLAUDE.md:83-118`
- Delete or Modify: `docs/superpowers/specs/2026-09-24-weekly-update-handoff-design.md`

**Interfaces:**
- Consumes: Design specifications from `docs/superpowers/specs/2026-09-27-autonomous-weekly-update-design.md`
- Produces: Updated operational documentation in `CLAUDE.md`

- [ ] **Step 1: Update "Weekly Automation" section in `CLAUDE.md`**

Replace the "Weekly Automation" section in `CLAUDE.md` to document the new architecture:

```markdown
### Weekly Automation

- **raider `weekly-update`** (Sun 03:00 local time): Runs autonomously on raider via `systemd.timers.weekly-update` (with `Persistent = true` to run upon wake/boot if sleeping).
  1. Operates inside an isolated checkout at `~/.local/share/nixos-weekly-update/nixos` (never touching `~/Code/nixos`).
  2. Runs `nix flake update` and verifies tier-1 builds via `just dry-run @tier1`.
  3. If build/eval breakage occurs (e.g. insecure packages, renamed options), invokes `agy` (Antigravity CLI) non-interactively to diagnose and fix configurations, guarded by an independent verification gate.
  4. Pushes valid commits to `master` and executes `just deploy @tier1` (pushing closures to `niks3.arsfeld.dev` and switching `basestar`, `galactica`, and `raider`).
  5. Dispatches run reports to both **ntfy** (`https://ntfy.arsfeld.one/backups`) and **email** (`admin@rosenfeld.one` -> `alex@rosenfeld.one`).
- **Manual Trigger**: Run `just auto-update` or `sudo systemctl start weekly-update`.
```

- [ ] **Step 2: Add deprecation note to `docs/superpowers/specs/2026-09-24-weekly-update-handoff-design.md`**

Add header notice:
```markdown
> **SUPERSEDED:** This design has been superseded by `2026-09-27-autonomous-weekly-update-design.md`, which replaces the GitHub Actions + galactica handoff with an autonomous agent on raider.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-09-24-weekly-update-handoff-design.md
git commit -m "docs: update CLAUDE.md weekly automation documentation"
```

---

### Task 5: End-to-End Verification & Formatting

**Files:**
- Formatting and evaluation check across entire repo.

- [ ] **Step 1: Format codebase**

Run: `just fmt`
Expected: Alejandra formats all nix files cleanly.

- [ ] **Step 2: Full evaluation check of tier-1 hosts**

Run: `nix eval .#nixosConfigurations.raider.config.systemd.services.weekly-update.serviceConfig.ExecStart`
Expected: Path to `weekly-update` executable in store.

Run: `nix eval .#nixosConfigurations.galactica.config.systemd.services.backrest.enable`
Expected: `true` (galactica evaluates cleanly without weekly-deploy).

Run: `nix eval .#nixosConfigurations.basestar.config.systemd.services.niks3.enable`
Expected: `true` (basestar evaluates cleanly).

- [ ] **Step 3: Commit formatting if any**

```bash
git add -u
git commit -m "style: format nix files with alejandra" || true
```
