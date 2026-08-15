# Backup Prune and Integrity Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every restic repo a scheduled prune and integrity check, give the OVH cold tier a structure-only check, and make galactica the single owner of prune/check for the shared `storage` repo.

**Architecture:** Two module changes (`constellation.backrest`, `constellation.rustic`) add the option surface, defaulting to on so repos added later are covered automatically. Every repo that exists today then sets its policy explicitly, so the defaults never silently activate anything in this change. The failure hook moves from plan level to repo level, which is where prune and check errors are raised.

**Tech Stack:** Nix / NixOS modules, Backrest 1.14.1 (wrapping restic), rustic 0.11.3, systemd timers.

**Spec:** `docs/superpowers/specs/2026-08-14-backup-prune-check-design.md`

## Global Constraints

- Conventional commits: `<type>(<scope>): <subject>`, scope is a hostname or `modules`. Never mention Claude.
- Commit straight to `master`. No feature branches, no worktrees.
- `just fmt` (alejandra) must pass; a pre-commit hook enforces it.
- `maxUnusedPercent` must never be `0` — Backrest renders it into `--max-unused 0%`, forcing a full repack every prune.
- No scheduled job may use `--read-data` against the OVH cold tier.
- Do not deploy anything in tasks 1–4. Task 5 is the only deploy, and task 6 is gated on its review.

## Test Harness

There is no unit-test framework for these modules. The test is to build the exact artifact the daemon consumes and assert on it. Both commands below are verified working. Run them from the repo root.

**Rendered Backrest `config.json` for a host:**

Build the host closure first. `nix eval --raw` returns a store path but does not
create it, and `nix-store --realise` cannot build an output path whose derivation
has not been instantiated — so on a locally modified module it fails with "path is
not valid". Building the toplevel realises every path in the closure, after which
the file is simply there to read.

```bash
bash -c 'set -e
host="$1"
nix build --no-link ".#nixosConfigurations.$host.config.system.build.toplevel"
script=$(nix eval --raw ".#nixosConfigurations.$host.config.systemd.services.backrest.serviceConfig.ExecStartPre")
tpl=$(grep -oE "/nix/store/[^ ]*-backrest-config\.json" "$script" | head -1)
cat "$tpl"
' _ galactica | jq .
```

**A rustic unit and the generated TOML:**

```bash
nix eval --raw '.#nixosConfigurations.galactica.config.systemd.services."rustic-ovh-check".serviceConfig.ExecStart'
nix eval --json '.#nixosConfigurations.galactica.config.systemd.timers."rustic-ovh-check".timerConfig'
```

**Baseline before any work** (confirms the gap this plan closes):

```bash
# repo keys today: ["autoUnlock","env","flags","id","password","uri"] — no prunePolicy, no checkPolicy, no hooks
```

## File Structure

| File | Responsibility |
|---|---|
| `modules/constellation/backrest.nix` | Modify: add `prune`/`check`/`hooks` to `repoType`, render them, move the failure hook to repo level |
| `modules/constellation/rustic.nix` | Modify: add `checkTimerConfig` + `rustic-<name>-check` unit |
| `hosts/galactica/backup/backrest-client.nix` | Modify: explicit policies for 4 repos, new `storage` repo entry |
| `hosts/galactica/backup/rustic-ovh.nix` | Modify: add `checkTimerConfig` |
| `hosts/basestar/configuration.nix` | Modify: opt out of prune/check; later, retention |
| `hosts/raider/configuration.nix` | Modify: opt out of prune/check; later, retention |
| `hosts/pegasus/backup/backup-client.nix` | Modify: opt out of prune/check; later, retention |

---

### Task 1: Backrest prune/check policies and repo-level failure hook

**Files:**
- Modify: `modules/constellation/backrest.nix`

**Interfaces:**
- Produces: `constellation.backrest.repos.<name>.prune` (nullOr submodule with `schedule`, `maxUnusedPercent`, `maxUnusedBytes`), `.check` (nullOr submodule with `schedule`, `readDataSubsetPercent`), `.hooks` (nullOr list). Tasks 3 and 4 set these.
- Consumes: existing `scheduleType`, `renderSchedule`, `config.constellation.backupNotify.script`.

- [ ] **Step 1: Capture the failing baseline**

```bash
bash -c 'set -e
nix build --no-link ".#nixosConfigurations.galactica.config.system.build.toplevel"
script=$(nix eval --raw ".#nixosConfigurations.galactica.config.systemd.services.backrest.serviceConfig.ExecStartPre")
tpl=$(grep -oE "/nix/store/[^ ]*-backrest-config\.json" "$script" | head -1)
jq -c "{repo0: (.repos[0]|keys), plan0hooks: (.plans[0].hooks|length)}" "$tpl"
'
```

Expected: `{"repo0":["autoUnlock","env","flags","id","password","uri"],"plan0hooks":1}` — no `prunePolicy`, no `checkPolicy`, no repo `hooks`, and the failure hook still on the plan.

- [ ] **Step 2: Add the two policy submodules and their renderers**

Add to the `let` block in `modules/constellation/backrest.nix`, next to `renderRetention`:

```nix
  # Prune and check are repo-scoped in Backrest, and an ABSENT policy means
  # "never": taskprune.go / taskcheck.go both return NeverScheduledTask when
  # <Policy>.GetSchedule() is nil. That is how every repo in this fleet went
  # unpruned and unchecked from the start. Both therefore default to a monthly
  # schedule, so a repo added later is covered without anyone remembering to
  # opt in; set the option to null to disable deliberately.
  prunePolicyType = types.submodule {
    options = {
      schedule = mkOption {
        type = scheduleType;
        default = {maxFrequencyDays = 30;};
        description = "When to prune. Same Schedule shape as plan schedules.";
      };
      maxUnusedPercent = mkOption {
        type = types.number;
        default = 10;
        description = ''
          Unused space restic may leave behind, as a percentage. NEVER set this
          to 0: Backrest renders it straight into `--max-unused <n>%`, and 0%
          forces a full repack on every prune. Backrest's own 25% fallback
          applies only when the whole policy is absent, which it never is once
          this module emits one.
        '';
      };
      maxUnusedBytes = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Absolute byte budget. Takes precedence over maxUnusedPercent when set.";
      };
    };
  };

  checkPolicyType = types.submodule {
    options = {
      schedule = mkOption {
        type = scheduleType;
        default = {maxFrequencyDays = 30;};
        description = "When to check. Same Schedule shape as plan schedules.";
      };
      readDataSubsetPercent = mkOption {
        type = types.nullOr types.number;
        default = null;
        description = ''
          Percentage of pack data to re-read. null means structure-only, which
          verifies index/snapshot/tree consistency without downloading packs.
          Leave it null for every remote repo — reading data costs egress.
        '';
      };
    };
  };

  renderPrunePolicy = p:
    {schedule = renderSchedule p.schedule;}
    // (
      if p.maxUnusedBytes != null
      then {maxUnusedBytes = p.maxUnusedBytes;}
      else {maxUnusedPercent = p.maxUnusedPercent;}
    );

  # CheckPolicy models its two modes as a proto oneof, so exactly one arm must
  # be set — structureOnly is not an implicit default.
  renderCheckPolicy = c:
    {schedule = renderSchedule c.schedule;}
    // (
      if c.readDataSubsetPercent != null
      then {readDataSubsetPercent = c.readDataSubsetPercent;}
      else {structureOnly = true;}
    );
```

- [ ] **Step 3: Move the failure hook to repo level**

Replace the existing `defaultFailureHook` comment and binding with:

```nix
  # One failure hook, attached to the REPO rather than to plans.
  #
  # NotifyError prepends CONDITION_ANY_ERROR to every error path
  # (tasks/errors.go), and the explicit ExecuteHooks calls in taskbackup.go,
  # taskprune.go and taskcheck.go include it too — so this single condition
  # covers backup, forget, prune, check and index failures.
  #
  # It lives on the repo and NOT also on plans because TasksTriggeredByEvent
  # iterates repo.GetHooks() AND plan.GetHooks(). A plan-level copy matching the
  # same condition would send a second ntfy message for every failure. Repo
  # level also covers repos that have no plans at all, which is the only place
  # prune and check errors on galactica's `storage` entry could ever surface.
  #
  # {{.Plan.Id}} is safe here: when a task has no plan, Backrest substitutes a
  # placeholder Plan carrying only the ID (taskrunnerimpl.go), so this renders
  # the real plan for backup failures and an empty string for repo-scoped prune
  # and check failures. It does not error.
  #
  # The POST itself lives in constellation.backupNotify so rustic's units share
  # exactly one implementation. Backrest cannot use the templated
  # backup-notify@.service — it needs Backrest's own {{...}} expansion, which
  # only happens inside an actionCommand.
  defaultFailureHook = {
    conditions = ["CONDITION_ANY_ERROR"];
    actionCommand = {
      command = ''
        #!${pkgs.bash}/bin/bash
        ${config.constellation.backupNotify.script} \
          'Backrest ${cfg.instance}: {{.Repo.Id}}/{{.Plan.Id}} failed' \
          '{{.Event}} on {{.Repo.Id}}/{{.Plan.Id}} (host ${cfg.instance}): {{.Error}}'
      '';
    };
  };
```

- [ ] **Step 4: Emit the new fields from `renderRepo`**

Replace `renderRepo` with:

```nix
  renderRepo = name: repo:
    {
      id = name;
      uri = repo.uri;
      password = ""; # restic reads from RESTIC_PASSWORD_FILE via env below
      env =
        ["RESTIC_PASSWORD_FILE=${toString repo.passwordFile}"]
        ++ repo.env;
      flags = repo.flags;
      autoUnlock = repo.autoUnlock;
      hooks =
        if repo.hooks == null
        then [defaultFailureHook]
        else repo.hooks;
      # autoInitialize is set by the merge script for repos that have no guid
      # yet (new repos). Once a guid is present autoInitialize must be absent —
      # Backrest rejects configs that set both.
    }
    // optionalAttrs (repo.prune != null) {prunePolicy = renderPrunePolicy repo.prune;}
    // optionalAttrs (repo.check != null) {checkPolicy = renderCheckPolicy repo.check;};
```

- [ ] **Step 5: Drop the now-duplicate plan-level hook default**

In `renderPlan`, replace the `hooks` attribute with:

```nix
    hooks =
      if plan.hooks == null
      then [] # the default failure hook is repo-level; see defaultFailureHook
      else plan.hooks;
```

- [ ] **Step 6: Add the three new options to `repoType`**

Add inside `repoType`'s `options`, after `autoUnlock`:

```nix
      prune = mkOption {
        type = types.nullOr prunePolicyType;
        default = {};
        description = "Prune policy for this repo. null disables pruning entirely.";
      };
      check = mkOption {
        type = types.nullOr checkPolicyType;
        default = {};
        description = "Integrity check policy for this repo. null disables checks entirely.";
      };
      hooks = mkOption {
        type = types.nullOr (types.listOf types.attrs);
        default = null;
        description = "Repo hooks. null = module default failure hook. [] = no hooks.";
      };
```

Then update `planType.hooks`'s description to read:

```nix
        description = "Per-plan hooks. null = none (the default failure hook is repo-level). [] = no hooks.";
```

- [ ] **Step 7: Format and verify the rendered config**

```bash
just fmt
bash -c 'set -e
nix build --no-link ".#nixosConfigurations.galactica.config.system.build.toplevel"
script=$(nix eval --raw ".#nixosConfigurations.galactica.config.systemd.services.backrest.serviceConfig.ExecStartPre")
tpl=$(grep -oE "/nix/store/[^ ]*-backrest-config\.json" "$script" | head -1)
jq "{
  repos: [.repos[] | {id, prune: .prunePolicy, check: .checkPolicy, hookConds: [.hooks[].conditions]}],
  planHooks: [.plans[] | {id, hooks}]
}" "$tpl"
'
```

Expected, for all three of galactica's current repos:
- `prune.schedule` = `{"clock":"CLOCK_LOCAL","maxFrequencyDays":30}` and `prune.maxUnusedPercent` = `10` (**never 0**)
- `check.schedule` same, and `check.structureOnly` = `true`
- `hookConds` = `[["CONDITION_ANY_ERROR"]]`
- every entry in `planHooks` has `hooks` absent or `[]`

- [ ] **Step 8: Confirm every host still evaluates**

```bash
for h in galactica basestar raider pegasus; do
  nix build --no-link ".#nixosConfigurations.$h.config.system.build.toplevel" && echo "$h OK"
done
```

Expected: four `OK` lines.

- [ ] **Step 9: Commit**

```bash
git add modules/constellation/backrest.nix
git commit -m "feat(modules): add backrest prune and check policies" -m "An absent policy means never in Backrest, so no repo in the fleet has ever
been pruned or integrity-checked. Both now default to a monthly schedule.

Moves the default failure hook from plan level to repo level: prune and check
errors are raised against repo hooks, ANY_ERROR covers every error path, and
keeping a plan-level copy would double-notify since both hook sets are
iterated."
```

---

### Task 2: rustic structure-only check unit

**Files:**
- Modify: `modules/constellation/rustic.nix`

**Interfaces:**
- Produces: `constellation.rustic.profiles.<name>.checkTimerConfig` and the unit `rustic-<name>-check.service`. Task 3 sets the timer for the `ovh` profile.

- [ ] **Step 1: Verify the unit does not exist yet**

```bash
nix eval --raw '.#nixosConfigurations.galactica.config.systemd.services."rustic-ovh-check".serviceConfig.ExecStart'
```

Expected: FAIL — `error: attribute 'rustic-ovh-check' missing`.

- [ ] **Step 2: Register the new module key**

In `moduleKeys`, add `"checkTimerConfig"` after `"pruneTimerConfig"`. This is required: anything absent from that list is written verbatim into the generated TOML, where opendal ignores unknown keys silently rather than erroring.

- [ ] **Step 3: Add the check service**

Add after `pruneServices` in the `let` block:

```nix
  # Structure-only, deliberately. `rustic check` reads pack CONTENTS only under
  # --read-data (rustic_core's check.rs gates it, and --read-data-subset is
  # declared requires="read_data"). Without that flag it does list_with_size
  # against both backends and reads snapshots, index and tree packs from the
  # HOT repo — so on a hot/cold repository nothing is retrieved from tape, and
  # it still catches a pack the index references but the cold bucket lacks.
  #
  # --read-data is not exposed as an option on purpose. Against OVH Cold
  # Archive every pack would go through restore-object with warm-up-batch = 1
  # and a poll that waits up to 48h PER PACK, plus retrieval billing and 7-day
  # restore copies. There is no schedule on which that is acceptable.
  checkServices = mapAttrs' (name: profile:
    nameValuePair "rustic-${name}-check" {
      description = "rustic check (profile ${name})";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = profileEnv profile;
      onFailure = ["backup-notify@rustic-${name}-check.service"];
      serviceConfig =
        hardening
        // {
          Type = "oneshot";
          ExecStart = "${cfg.package}/bin/rustic -P ${name} check";
          EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
        };
    })
  cfg.profiles;
```

- [ ] **Step 4: Add the `checkTimerConfig` option**

Add to `profileType`'s `options`, after `pruneTimerConfig`:

```nix
      checkTimerConfig = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "systemd timer for the check unit. null means manual-only.";
        example = literalExpression ''{OnCalendar = "*-*-06 09:00:00";}'';
      };
```

- [ ] **Step 5: Wire the service and timer into `config`**

```nix
    systemd.services = backupServices // pruneServices // checkServices;
    systemd.timers =
      (mkTimer "" "timerConfig")
      // (mkTimer "-prune" "pruneTimerConfig")
      // (mkTimer "-check" "checkTimerConfig");
```

Also update the module's header comment, which enumerates the generated units, to list `rustic-<name>-check.service` and `rustic-<name>-check.timer`.

- [ ] **Step 6: Verify the unit and the TOML**

```bash
just fmt
nix eval --raw '.#nixosConfigurations.galactica.config.systemd.services."rustic-ovh-check".serviceConfig.ExecStart'
```

Expected: ends with `/bin/rustic -P ovh check` and contains **no** `--read-data`.

```bash
bash -c 'set -e
nix build --no-link ".#nixosConfigurations.galactica.config.system.build.toplevel"
t=$(nix eval --raw ".#nixosConfigurations.galactica.config.environment.etc.\"rustic/ovh.toml\".source")
grep -nE "TimerConfig|maxAgeHours|pruneArgs|substituteEnv" "$t" && echo "LEAK" || echo "no module keys leaked into TOML (good)"
'
```

Expected: `no module keys leaked into TOML (good)`.

- [ ] **Step 7: Confirm galactica builds**

```bash
nix build --no-link '.#nixosConfigurations.galactica.config.system.build.toplevel' && echo OK
```

Expected: `OK`.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/rustic.nix
git commit -m "feat(modules): add a structure-only rustic check unit" -m "The cold tier generated backup and forget+prune units but nothing that ever
verified the repository. Plain rustic check is list-only plus hot-repo reads,
so it costs nothing against tape while still catching a pack the index
references but the cold bucket lacks. --read-data is not exposed: every pack
would warm up from DEEP_ARCHIVE one at a time."
```

---

### Task 3: galactica takes ownership

**Files:**
- Modify: `hosts/galactica/backup/backrest-client.nix`
- Modify: `hosts/galactica/backup/rustic-ovh.nix`

**Interfaces:**
- Consumes: `prune` / `check` from Task 1, `checkTimerConfig` from Task 2.
- Produces: a repo named `storage` on galactica, which task 5 verifies by guid.

- [ ] **Step 1: Add the schedule helper**

In `hosts/galactica/backup/backrest-client.nix`, add to the `let` block after `remoteRetention`:

```nix
  # One repo per day, check at 09:00 and prune at 12:00 the same day. Nothing
  # lands on the 1st (rustic-ovh-prune) or on a Sunday (the 02:30-07:30 backup
  # block), and the three-hour gap keeps a prune from starting while that
  # repo's own check still holds the lock.
  #
  # readDataPercent re-reads that share of pack data and is only worth it where
  # reads are free. null = structure-only, which is mandatory for the two
  # remote repos: re-reading 2.9 TiB over rclone would cost egress every month.
  policies = day: readDataPercent: {
    check =
      {schedule.cron = "0 9 ${toString day} * *";}
      // lib.optionalAttrs (readDataPercent != null) {
        readDataSubsetPercent = readDataPercent;
      };
    prune.schedule.cron = "0 12 ${toString day} * *";
  };
```

- [ ] **Step 2: Apply policies and add the `storage` repo**

Replace the `repos` attribute with:

```nix
    repos = {
      local =
        {
          uri = "/mnt/storage/backups/restic";
          passwordFile = config.sops.secrets."restic-password".path;
        }
        // policies 2 5;

      # The repo galactica's own restic REST server serves, which basestar,
      # raider and pegasus all write to over rest://. Declared here with no
      # plans: galactica owns prune and check for it because it is the host
      # holding the disk, and three client instances pruning one repo would
      # just contend for the same lock.
      #
      # Addressed as a local path rather than rest://galactica:8000/ because
      # prune is I/O-heavy and this skips the HTTP round trip. Verified that
      # this path is the repo root (config, data, index, keys, locks,
      # snapshots), and restic locks are objects inside the repo, so a
      # local-path prune and a REST client still see each other's locks.
      storage =
        {
          uri = "/mnt/storage/backups/restic-server";
          passwordFile = config.sops.secrets."restic-password".path;
          # basestar writes here daily, so 48h is the right staleness bound.
          maxAgeHours = 48;
        }
        // policies 3 5;

      hetzner =
        {
          uri = "rclone:hetzner:backups/restic";
          passwordFile = config.sops.secrets."restic-password".path;
          envFile = config.sops.secrets."hetzner-webdav-env".path;
          # hetzner-system (30 4 * * 0) and hetzner (30 5 * * 0) are both
          # Sunday-only — weekly. 48h would report stale every week; 192h is
          # 8 days, one day of slack past the interval (matches ovh).
          maxAgeHours = 192;
        }
        // policies 4 null;

      pegasus =
        {
          uri = "rest:http://pegasus.bat-boa.ts.net:8000/";
          passwordFile = config.sops.secrets."restic-password".path;
          # pegasus-system (30 6 * * 0) and pegasus (30 7 * * 0) are both
          # Sunday-only — weekly. Same 192h reasoning as hetzner above.
          maxAgeHours = 192;
        }
        // policies 5 null;
    };
```

- [ ] **Step 3: Add the cold-tier check timer**

In `hosts/galactica/backup/rustic-ovh.nix`, add inside `profiles.ovh`, after `pruneArgs`:

```nix
      # Structure-only check on the 6th, continuing the one-repo-per-day
      # rotation the restic repos use. List-only against both buckets plus hot
      # reads, so nothing is retrieved from tape — see the checkServices
      # comment in constellation.rustic for why --read-data is not an option.
      checkTimerConfig = {
        OnCalendar = "*-*-06 09:00:00";
        Persistent = true;
      };
```

- [ ] **Step 4: Verify the four repos and their schedules**

```bash
just fmt
bash -c 'set -e
nix build --no-link ".#nixosConfigurations.galactica.config.system.build.toplevel"
script=$(nix eval --raw ".#nixosConfigurations.galactica.config.systemd.services.backrest.serviceConfig.ExecStartPre")
tpl=$(grep -oE "/nix/store/[^ ]*-backrest-config\.json" "$script" | head -1)
jq -S "[.repos[] | {id, uri, checkCron: .checkPolicy.schedule.cron, readData: .checkPolicy.readDataSubsetPercent, structureOnly: .checkPolicy.structureOnly, pruneCron: .prunePolicy.schedule.cron, maxUnused: .prunePolicy.maxUnusedPercent}]" "$tpl"
'
```

Expected exactly:

| id | checkCron | pruneCron | data mode | maxUnused |
|---|---|---|---|---|
| `local` | `0 9 2 * *` | `0 12 2 * *` | `readDataSubsetPercent: 5` | 10 |
| `storage` | `0 9 3 * *` | `0 12 3 * *` | `readDataSubsetPercent: 5` | 10 |
| `hetzner` | `0 9 4 * *` | `0 12 4 * *` | `structureOnly: true` | 10 |
| `pegasus` | `0 9 5 * *` | `0 12 5 * *` | `structureOnly: true` | 10 |

- [ ] **Step 5: Verify the cold-tier timer**

```bash
nix eval --json '.#nixosConfigurations.galactica.config.systemd.timers."rustic-ovh-check".timerConfig'
```

Expected: `{"OnCalendar":"*-*-06 09:00:00","Persistent":true}`.

- [ ] **Step 6: Build galactica**

```bash
nix build --no-link '.#nixosConfigurations.galactica.config.system.build.toplevel' && echo OK
```

Expected: `OK`.

- [ ] **Step 7: Commit**

```bash
git add hosts/galactica/backup/backrest-client.nix hosts/galactica/backup/rustic-ovh.nix
git commit -m "feat(galactica): own prune and check for every backup repo" -m "Adds a storage repo entry for the repository galactica's own REST server
serves, so one host owns prune and check for it instead of three clients
contending for the same lock. Schedules run one repo per day on days 2-6,
avoiding the 1st (ovh prune) and Sundays (the backup block).

Data-subset reads only on the two local-disk repos; the remote repos and the
cold tier are structure-only so no scheduled job ever pays egress."
```

---

### Task 4: clients opt out of the shared repo

**Files:**
- Modify: `hosts/basestar/configuration.nix`
- Modify: `hosts/raider/configuration.nix`
- Modify: `hosts/pegasus/backup/backup-client.nix`

**Interfaces:**
- Consumes: `prune` / `check` from Task 1.

- [ ] **Step 1: basestar**

In `constellation.backrest.repos`, add to **both** the `storage` and `pegasus` entries:

```nix
        # galactica owns prune and check for this repo (it hosts the disk).
        # Three instances pruning one repository would contend for one lock.
        prune = null;
        check = null;
```

- [ ] **Step 2: raider**

Add the same two lines, with the same comment, to `repos.storage`.

- [ ] **Step 3: pegasus**

Add the same two lines, with the same comment, to `repos.storage`.

- [ ] **Step 4: Verify no client renders a policy**

```bash
just fmt
for h in basestar raider pegasus; do
  echo "=== $h ==="
  bash -c 'set -e
  nix build --no-link ".#nixosConfigurations.$1.config.system.build.toplevel"
  script=$(nix eval --raw ".#nixosConfigurations.$1.config.systemd.services.backrest.serviceConfig.ExecStartPre")
  tpl=$(grep -oE "/nix/store/[^ ]*-backrest-config\.json" "$script" | head -1)
  jq -c "[.repos[] | {id, prune: .prunePolicy, check: .checkPolicy, hookConds: [.hooks[].conditions]}]" "$tpl"
  ' _ "$h"
done
```

Expected for every repo on all three hosts: `prune` and `check` are `null`, and `hookConds` is `[["CONDITION_ANY_ERROR"]]` (the failure hook is still attached — only prune/check are opted out).

- [ ] **Step 5: Build the three clients**

```bash
for h in basestar raider pegasus; do
  nix build --no-link ".#nixosConfigurations.$h.config.system.build.toplevel" && echo "$h OK"
done
```

Expected: three `OK` lines.

- [ ] **Step 6: Commit**

```bash
git add hosts/basestar/configuration.nix hosts/raider/configuration.nix hosts/pegasus/backup/backup-client.nix
git commit -m "fix(modules): let galactica own prune and check for the shared repo" -m "basestar, raider and pegasus all write to galactica's restic REST server. With
prune and check now on by default, each would schedule its own prune against
the same repository and contend for one lock. galactica owns it instead."
```

---

### Task 5: Deploy and verify

**Files:** none — this task is verification only.

**This is the only task that deploys.** Task 6 must not start until this task's checks pass.

- [ ] **Step 1: Record pre-prune sizes**

```bash
ssh galactica.bat-boa.ts.net 'sudo du -sh /mnt/storage/backups/restic /mnt/storage/backups/restic-server'
```

Expected roughly: `861G` and `445G`. Record the exact numbers — task 6 compares against them.

- [ ] **Step 2: Deploy all four hosts**

```bash
just deploy galactica basestar raider
just deploy pegasus
```

Expected: each host activates without error.

- [ ] **Step 3: Verify the `storage` repo adopted the existing repository**

This is the gate. `mergeConfigScript` sets `autoInitialize: true` for any repo with no guid, so a wrong URI would create a fresh empty repository and every operation afterwards would report success into the void.

```bash
ssh galactica.bat-boa.ts.net 'sudo jq -r ".repos[] | select(.id==\"storage\") | .guid" /var/lib/backrest/config.json'
```

Expected **exactly**: `8f51bfd26c36f60517b376aea2dd2376c7c2042e1e6635a66aba80aba20b3174`

If it differs or is empty: **stop**. Do not proceed to task 6. The entry did not adopt basestar's repo.

- [ ] **Step 4: Verify the live config on every host**

```bash
for h in galactica basestar raider pegasus; do
  echo "=== $h ==="
  ssh $h.bat-boa.ts.net 'sudo jq -c "[.repos[] | {id, prune: .prunePolicy.schedule.cron, check: .checkPolicy.schedule.cron}]" /var/lib/backrest/config.json'
done
```

Expected: galactica shows crons on days 2–5; the other three show `null` for both on every repo.

- [ ] **Step 5: Confirm backrest is healthy everywhere**

```bash
for h in galactica basestar raider pegasus; do
  echo -n "$h: "; ssh $h.bat-boa.ts.net 'systemctl is-active backrest'
done
```

Expected: four `active` lines. A config Backrest rejects makes the daemon fail to start, so this is the real syntax check.

- [ ] **Step 6: Run a check by hand on each repo before any scheduled prune**

In the Backrest UI (`backrest-galactica.arsfeld.one`), run "Check Now" on `local`, `storage`, `hetzner` and `pegasus`. Then the cold tier:

```bash
ssh galactica.bat-boa.ts.net 'sudo systemctl start rustic-ovh-check && systemctl status rustic-ovh-check --no-pager -n 20'
```

Expected: all five report success. A repo that fails its check must not be pruned — investigate before task 6.

- [ ] **Step 7: Confirm the notification path**

```bash
ssh galactica.bat-boa.ts.net 'sudo systemctl start backup-notify@manual-test.service; journalctl -u backup-notify@manual-test --no-pager -n 10'
```

Expected: the unit succeeds and an ntfy message arrives on the `backups` topic. This confirms the hook path that prune and check failures now depend on.

---

### Task 6: Client retention (gated on Task 5)

**Files:**
- Modify: `hosts/basestar/configuration.nix`
- Modify: `hosts/raider/configuration.nix`
- Modify: `hosts/pegasus/backup/backup-client.nix`

**Do not start this task until Task 5 step 3 matched the expected guid and step 6 reported clean checks.** This is the change that makes the first prune delete real history: basestar has 59 snapshots, raider 56, pegasus 10, and all three currently keep everything.

- [ ] **Step 1: Set retention on all three plans**

In each host's `plans.system`, add:

```nix
      # Was keep-all, which combined with the absent prune policy meant nothing
      # was ever removed from this repo. Matches the d7/w4/m6 that galactica
      # already uses for its hetzner and pegasus plans.
      retention = {
        daily = 7;
        weekly = 4;
        monthly = 6;
      };
```

- [ ] **Step 2: Verify the rendered retention**

```bash
just fmt
for h in basestar raider pegasus; do
  echo "=== $h ==="
  bash -c 'set -e
  nix build --no-link ".#nixosConfigurations.$1.config.system.build.toplevel"
  script=$(nix eval --raw ".#nixosConfigurations.$1.config.systemd.services.backrest.serviceConfig.ExecStartPre")
  tpl=$(grep -oE "/nix/store/[^ ]*-backrest-config\.json" "$script" | head -1)
  jq -c "[.plans[] | {id, retention}]" "$tpl"
  ' _ "$h"
done
```

Expected: `policyTimeBucketed` with `{"daily":7,"weekly":4,"monthly":6}` on each, and **no** `policyKeepAll` anywhere.

- [ ] **Step 3: Commit and deploy**

```bash
git add hosts/basestar/configuration.nix hosts/raider/configuration.nix hosts/pegasus/backup/backup-client.nix
git commit -m "fix(modules): retain d7/w4/m6 on the shared storage repo" -m "keep-all plus no prune policy meant nothing was ever removed from the repo
galactica serves. Matches the retention galactica already uses for its own
remote tiers."
just deploy basestar raider
just deploy pegasus
```

- [ ] **Step 4: Let one forget cycle run, then review before anything is reclaimed**

Wait for each host's next scheduled backup (basestar 03:30 daily, raider ~24h, pegasus Sun 03:30), then:

```bash
ssh galactica.bat-boa.ts.net 'sudo RESTIC_PASSWORD_FILE=/run/secrets/restic-password restic -r /mnt/storage/backups/restic-server snapshots --json' \
  | jq -r "group_by(.hostname)[] | {host: .[0].hostname, count: length, latest: (max_by(.time)|.time)}"
```

Expected: basestar and raider drop from 59/56 toward roughly 17 each; pegasus is largely unchanged at 10. The `cloud` host stays at 17 — no plan owns it, so no retention policy expires it. That is known and out of scope.

Review this before the prune on the 3rd reclaims the space.

- [ ] **Step 5: After the scheduled prune, confirm space was reclaimed**

```bash
ssh galactica.bat-boa.ts.net 'sudo du -sh /mnt/storage/backups/restic /mnt/storage/backups/restic-server'
```

Expected: both smaller than the sizes recorded in Task 5 step 1.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| `repoType` gains `prune`/`check`/`hooks` | 1 |
| `maxUnusedPercent` guard rail | 1 (step 2 comment, step 7 assertion) |
| Failure hook moves to repo level | 1 (steps 3, 5) |
| rustic check unit, `checkTimerConfig`, `moduleKeys` | 2 |
| No `--read-data` exposed | 2 (step 3 comment, step 6 assertion) |
| galactica owns `storage`, local-path URI | 3 |
| Schedule table (days 2–6) | 3 (steps 2, 3), asserted in step 4 |
| Client opt-outs | 4 |
| Rollout step 1 (guid verification) | 5 (step 3) |
| Rollout step 2 (manual checks first) | 5 (step 6) |
| Rollout step 3 (retention, separate commit, review gate) | 6 |
| Rollout step 4 (confirm reclaimed space) | 6 (step 5) |

Out-of-scope items in the spec (per-host freshness filter, orphan `cloud` snapshots, hetzner/OVH overlap, pegasus absent from the weekly sweep) correctly have no tasks.

**Placeholder scan:** No TBD/TODO. Every code step carries the actual Nix. Every test step carries the exact command and its expected output.

**Type consistency:** `prune`/`check`/`hooks` are named identically in tasks 1, 3, 4 and 6. `renderPrunePolicy`/`renderCheckPolicy` are defined in task 1 step 2 and used in step 4. `policies day readDataPercent` is defined in task 3 step 1 and applied in step 2. `checkTimerConfig` is defined in task 2 step 4 and set in task 3 step 3. `checkServices` is defined in task 2 step 3 and wired in step 5.
