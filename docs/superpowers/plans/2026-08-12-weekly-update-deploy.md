# Weekly Update and Tier-1 Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the weekly flake update actually land on the fleet — GitHub proves tier-1 builds and commits the lock, galactica deploys tier-1 without ever compiling, and one ntfy summary reports failed units and stale backups every week.

**Architecture:** Two owners, one contract. GitHub Actions owns `flake.lock` (update → build tier-1 → push closures to attic → commit). galactica owns the fleet (pull master → `colmena apply` under `max-jobs = 0` → verify over Tailscale SSH → notify). The deployer never builds, so it cannot OOM; a missing closure is a loud error rather than a local compile.

**Tech Stack:** Nix flakes, flake-parts, haumea module auto-loading, colmena, systemd timers, Tailscale SSH, rustic 0.11.3 / restic 0.18.1, jq, ntfy, GitHub Actions.

**Design spec:** `docs/superpowers/specs/2026-08-12-weekly-update-deploy-design.md`

## Global Constraints

- **Commit straight to master.** No feature branches, no worktrees in this repo.
- **Conventional commits:** `<type>(<scope>): <subject>`. Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`. Scopes: a hostname (`galactica`, `raider`, `basestar`) or `modules`, `secrets`, `home`. Never mention Claude in a commit message or author.
- **Run `just fmt` before every commit.** `format.yml` fails the build on unformatted Nix.
- **Modules under `modules/` are auto-loaded by haumea.** Never add an import for a new module file; hosts opt in with `constellation.<name>.enable = true`.
- **Tier-1 is `["basestar" "galactica" "raider"]`**, defined at `flake-modules/hosts.nix:27`. Never hardcode a second copy that can drift — derive it where the tooling allows.
- **No per-app firewall rules.** Nothing in this plan opens a port.
- **Verified environment facts** (measured on galactica, 2026-08-12): rustic 0.11.3, restic 0.18.1, one rustic profile named `ovh` with `OnCalendar = "Sun *-*-* 04:30:00"` (weekly), Tailscale SSH live and keyless from root@galactica to root@{raider,basestar}.
- **Build/deploy commands:** `just build <host>` to build, `just deploy <host>` to deploy, both inside `nix develop`.

## File Structure

| File | Responsibility |
|---|---|
| `.github/workflows/build.yml` (modify) | Gains an optional `hosts` input filtering the matrix; gains attic timeout tolerance |
| `.github/workflows/update.yml` (modify) | Passes tier-1 to `build.yml`, drops `[skip ci]`, notifies ntfy on failure |
| `modules/constellation/backup-status.nix` (create) | Aggregates every backup source on a host into one `backup-status` JSON command |
| `modules/constellation/rustic.nix` (modify) | Registers one `backup-status` source per profile; adds per-profile `maxAgeHours` |
| `modules/constellation/backrest.nix` (modify) | Registers one `backup-status` source per repo; adds per-repo `maxAgeHours` |
| `modules/constellation/weekly-deploy.nix` (create) | The timer, the deploy, the verification sweep, the summary |
| `modules/constellation/backup-notify.nix` (modify) | Neutral failure title so non-backup units can reuse it |
| `modules/constellation/common.nix` (modify) | Declares Tailscale SSH via `extraSetFlags` |
| `hosts/galactica/configuration.nix` (modify) | Enables `constellation.weeklyDeploy` |
| `hosts/galactica/backup/rustic-ovh.nix` (modify) | Sets `maxAgeHours = 192` for the weekly cold tier |

---

### Task 1: Pre-flight — prove substitution-only deploys are possible

**This task is blocking.** If colmena's evaluated closure differs from the closure CI built and pushed to attic, `max-jobs = 0` fails on every host and the entire design collapses. `just deploy` passes `--impure`; nothing in the flake obviously requires it (the only `builtins.readDir` calls, `flake-modules/hosts.nix:10` and `modules/refind-theme-regular.nix:82`, are on in-flake paths and therefore pure).

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-weekly-update-deploy-design.md` (record the finding)

**Interfaces:**
- Consumes: nothing
- Produces: a decision — whether `colmena apply` in Task 5 keeps `--impure` or drops it

- [ ] **Step 1: Confirm master is green and get its SHA**

```bash
cd /home/arosenfeld/Code/nixos
git fetch origin master
SHA=$(git rev-parse origin/master)
echo "$SHA"
gh run list --workflow=build.yml --limit 5
```

Expected: a `Build & Cache` run for `$SHA` with conclusion `success`. If master is not green, stop and fix CI first — Task 2 does that, so run Task 2 before this task in that case.

- [ ] **Step 2: Compare pure vs impure evaluation of the same closure**

Evaluate the pinned commit directly rather than touching the working tree — there are
uncommitted local changes (`hosts/raider/hardware-configuration.nix`), and a
`git checkout -- .` would silently destroy them:

```bash
cd /home/arosenfeld/Code/nixos
SHA=$(git rev-parse origin/master)
nix eval --raw "github:arsfeld/nixos/$SHA#nixosConfigurations.galactica.config.system.build.toplevel.drvPath"
echo
nix eval --impure --raw "github:arsfeld/nixos/$SHA#nixosConfigurations.galactica.config.system.build.toplevel.drvPath"
```

Expected: **the two paths are identical.** If they differ, `--impure` changes the derivation, and Task 5's `constellation.weeklyDeploy.impureEval` must be set to `false`.

- [ ] **Step 3: Prove the closure is actually substitutable from attic**

Use the same pinned ref so this tests the exact commit CI built, not whatever master
happens to be by now:

```bash
SHA=$(git -C /home/arosenfeld/Code/nixos rev-parse origin/master)
ssh galactica.bat-boa.ts.net \
  "NIX_CONFIG='max-jobs = 0' nix build --no-link --print-out-paths \
     'github:arsfeld/nixos/$SHA#nixosConfigurations.galactica.config.system.build.toplevel' 2>&1 | tail -20"
```

Expected: a `/nix/store/...` path printed with no `error:` lines. A failure mentioning `max-jobs` or `cannot build` means the closure is not in attic — check that `build.yml` pushed it for this commit before proceeding.

- [ ] **Step 4: Record the finding in the spec**

Append to the "Verification plan" section of the spec, replacing `<result>` with what you measured:

```markdown
**Pre-flight result (2026-08-12):** pure and impure evaluation of galactica's toplevel
produced <identical / differing> derivation paths, so Task 5 <keeps / drops> `--impure`.
Substitution-only build from attic on galactica: <succeeded / failed>.
```

- [ ] **Step 5: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/specs/2026-08-12-weekly-update-deploy-design.md
git commit -m "docs(galactica): record weekly-deploy pre-flight substitution result"
```

---

### Task 2: CI — tier-1 commit gate, attic tolerance, failure notification

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `.github/workflows/update.yml`

**Interfaces:**
- Consumes: the `tiers.tier1` flake output (`flake-modules/hosts.nix:27`), the `ciMatrix` flake output
- Produces: a `flake.lock` commit on master whenever tier-1 builds — the precondition Task 5's deploy depends on

- [ ] **Step 1: Verify the flake outputs the CI will read**

```bash
cd /home/arosenfeld/Code/nixos
nix eval --json '.#tiers.tier1'
nix eval --json '.#ciMatrix' | jq -c '[.[].host]'
```

Expected: `["basestar","galactica","raider"]` and a list of all ten hosts.

- [ ] **Step 2: Confirm the matrix filter expression works before putting it in YAML**

```bash
cd /home/arosenfeld/Code/nixos
nix eval --json '.#ciMatrix' \
  | jq -c --argjson want "$(nix eval --json '.#tiers.tier1')" \
      '[.[] | select(.host as $h | $want | index($h))]'
```

Expected: exactly three entries — basestar (with `runner: ubuntu-24.04-arm`), galactica, raider.

- [ ] **Step 3: Add the `hosts` input and attic tolerance to `build.yml`**

In the `workflow_call.inputs` block, after the existing `flake_lock` input:

```yaml
      hosts:
        description: "JSON array of host names to build. Empty builds every host in ciMatrix."
        required: false
        type: string
        default: ""
```

Replace the `Derive matrix from flake` step with:

```yaml
      - name: Derive matrix from flake
        id: gen
        env:
          HOSTS: ${{ inputs.hosts }}
        run: |
          set -euo pipefail
          include=$(nix eval --json '.#ciMatrix')
          if [ -n "${HOSTS}" ]; then
            include=$(printf '%s' "$include" \
              | jq -c --argjson want "$HOSTS" '[.[] | select(.host as $h | $want | index($h))]')
          fi
          echo "matrix={\"include\":${include}}" >> "$GITHUB_OUTPUT"
```

In **both** `cachix/install-nix-action@v31` steps, extend `extra_nix_config` to:

```yaml
          extra_nix_config: |
            extra-substituters = https://attic.arsfeld.dev/system
            extra-trusted-public-keys = system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=
            fallback = true
            connect-timeout = 5
            download-attempts = 3
```

- [ ] **Step 4: Gate the commit on tier-1 in `update.yml`**

Add a `tier1` output to the `update` job's `outputs` block:

```yaml
      tier1: ${{ steps.check.outputs.tier1 }}
```

Add this line to the `Update flake inputs` step, immediately after `nix flake update`:

```bash
          echo "tier1=$(nix eval --json '.#tiers.tier1')" >> "$GITHUB_OUTPUT"
```

Note it must come **before** the `git diff --quiet` early-exit, or a no-change week leaves `tier1` empty.

Pass it to the build job:

```yaml
  build:
    needs: update
    if: needs.update.outputs.has_changes == 'true'
    uses: ./.github/workflows/build.yml
    permissions:
      contents: read
    with:
      flake_lock: ${{ needs.update.outputs.flake_lock }}
      hosts: ${{ needs.update.outputs.tier1 }}
    secrets: inherit
```

- [ ] **Step 5: Drop `[skip ci]` so the resulting push validates the whole fleet**

In the `commit` job, change the commit line to:

```bash
          git commit -m "chore: update flake inputs"
```

The push then triggers `build.yml` across all ten hosts, caching the rest of the fleet after the commit rather than as a precondition for it.

- [ ] **Step 6: Add the failure notification job to `update.yml`**

Append to `update.yml`:

```yaml
  notify:
    needs: [update, build, commit]
    if: failure()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Notify ntfy
        env:
          NTFY_BASIC_AUTH_B64: ${{ secrets.NTFY_BASIC_AUTH_B64 }}
        run: |
          set -euo pipefail
          curl -sS --fail-with-body -X POST \
            -H "Authorization: Basic $NTFY_BASIC_AUTH_B64" \
            -H "Title: Weekly Update failed" \
            -H "Tags: warning,package" \
            --data-binary "flake.lock was NOT committed. Run: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}" \
            https://ntfy.arsfeld.one/backups
```

- [ ] **Step 7: Create the GitHub secret the notify job needs**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c sops --decrypt --extract '["ntfy-publisher-env"]' secrets/sops/ntfy-client.yaml
```

That prints an env-file line of the form `NTFY_BASIC_AUTH_B64=<value>`. Set the repo secret to the value only:

```bash
VALUE=$(nix develop -c sops --decrypt --extract '["ntfy-publisher-env"]' secrets/sops/ntfy-client.yaml \
  | grep '^NTFY_BASIC_AUTH_B64=' | cut -d= -f2-)
gh secret set NTFY_BASIC_AUTH_B64 --repo arsfeld/nixos --body "$VALUE"
gh secret list --repo arsfeld/nixos | grep NTFY
```

Expected: `NTFY_BASIC_AUTH_B64` appears in the list.

- [ ] **Step 8: Commit and exercise the workflow end to end**

```bash
cd /home/arosenfeld/Code/nixos
git add .github/workflows/build.yml .github/workflows/update.yml
git commit -m "ci(modules): gate the weekly lock commit on tier-1 and notify on failure"
git push origin master
gh workflow run update.yml --repo arsfeld/nixos
sleep 60 && gh run list --workflow=update.yml --limit 1
```

Expected: the run builds exactly three hosts (basestar, galactica, raider), not ten. Watch it to completion; if `flake.lock` changed and tier-1 built, a `chore: update flake inputs` commit lands on master and triggers a full ten-host `build.yml`.

---

### Task 3: `backup-status` aggregator and its rustic sources

galactica runs **both** rustic and backrest, so neither module can own the `backup-status` command outright — they each register sources and this module renders the aggregate.

**Files:**
- Create: `modules/constellation/backup-status.nix`
- Modify: `modules/constellation/rustic.nix`
- Modify: `hosts/galactica/backup/rustic-ovh.nix`

**Interfaces:**
- Consumes: nothing
- Produces: `constellation.backupStatus.sources`, a list of `{name, kind, command, maxAgeHours}` that Task 4 also appends to; and a `backup-status` executable on the system PATH printing a JSON array of `{name, kind, lastSnapshot, ageHours, maxAgeHours, ok, error}`

- [ ] **Step 1: Write the failing test — the command does not exist yet**

```bash
ssh galactica.bat-boa.ts.net 'backup-status'
```

Expected: FAIL with `bash: backup-status: command not found`.

- [ ] **Step 2: Create the aggregator module**

Create `modules/constellation/backup-status.nix`:

```nix
# Constellation backup-status module
#
# One `backup-status` command per host, aggregating every backup orchestrator
# that host runs. galactica runs both rustic and backrest, so a script owned by
# either module alone would collide on the name; instead each module appends a
# source here and this module renders the aggregate.
#
# stdout is a JSON array, one object per repo/profile:
#   {name, kind, lastSnapshot, ageHours, maxAgeHours, ok, error}
#
# A source that cannot be queried reports ok:false with error set. It never
# aborts the run: a broken rclone repo must not hide a healthy local one.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backupStatus;

  sourceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Repo or profile name, unique within the host.";
      };
      kind = mkOption {
        type = types.enum ["rustic" "restic"];
        description = ''
          Which snapshot JSON shape `command` produces. rustic emits an array of
          {group_key, snapshots}; restic emits a flat array of snapshots.
        '';
      };
      command = mkOption {
        type = types.str;
        description = "Shell command printing snapshot JSON on stdout.";
      };
      maxAgeHours = mkOption {
        type = types.int;
        default = 48;
        description = ''
          Age above which this source reports ok:false. Must exceed the backup's
          own interval — galactica's weekly rustic profile needs 192, not the 48
          that suits a daily plan, or it reports stale every single week.
        '';
      };
    };
  };

  manifest = pkgs.writeText "backup-status-sources.json" (
    builtins.toJSON (map (s: {inherit (s) name kind command maxAgeHours;}) cfg.sources)
  );

  # Timestamps carry fractional seconds and a numeric offset
  # (2026-08-09T04:44:41.226088185-04:00). jq's fromdateiso8601 rejects that
  # form, and lexical sorting is wrong across differing offsets, so epoch
  # conversion goes through `date -d`.
  statusScript = pkgs.writeShellScriptBin "backup-status" ''
    set -uo pipefail
    export PATH=${makeBinPath [pkgs.jq pkgs.coreutils pkgs.gawk]}:$PATH

    now=$(date +%s)
    out=""

    while IFS=$'\t' read -r name kind cmd maxage; do
      err="null"; last="null"; age="null"; ok="false"

      if raw=$(eval "$cmd" 2>/dev/null); then
        if [ "$kind" = "rustic" ]; then
          filter='[.[].snapshots[].time] | .[]'
        else
          filter='[.[].time] | .[]'
        fi

        if times=$(printf '%s' "$raw" | jq -r "$filter" 2>/dev/null); then
          best=0; bestiso=""
          for t in $times; do
            e=$(date -d "$t" +%s 2>/dev/null) || continue
            if [ "$e" -gt "$best" ]; then best=$e; bestiso=$t; fi
          done

          if [ "$best" -eq 0 ]; then
            err='"no snapshots"'
          else
            last="\"$bestiso\""
            age=$(awk -v n="$now" -v b="$best" 'BEGIN{printf "%.1f",(n-b)/3600}')
            ok=$(awk -v a="$age" -v m="$maxage" 'BEGIN{print (a<=m)?"true":"false"}')
          fi
        else
          err='"unparseable snapshot json"'
        fi
      else
        err='"query failed"'
      fi

      out="$out$(jq -nc \
        --arg name "$name" --arg kind "$kind" \
        --argjson last "$last" --argjson age "$age" \
        --argjson max "$maxage" --argjson ok "$ok" --argjson err "$err" \
        '{name:$name,kind:$kind,lastSnapshot:$last,ageHours:$age,maxAgeHours:$max,ok:$ok,error:$err}')"
    done < <(jq -r '.[] | [.name,.kind,.command,.maxAgeHours] | @tsv' ${manifest})

    printf '%s' "$out" | jq -s '.'
  '';
in {
  options.constellation.backupStatus = {
    enable = mkEnableOption "aggregated backup freshness reporting";

    sources = mkOption {
      type = types.listOf sourceType;
      default = [];
      description = "Backup sources to query. Appended to by rustic.nix and backrest.nix.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [statusScript];
  };
}
```

- [ ] **Step 3: Add `maxAgeHours` to rustic's profile type**

In `modules/constellation/rustic.nix`, add to `profileType.options` (after `substituteEnv`):

```nix
      maxAgeHours = mkOption {
        type = types.int;
        default = 48;
        description = ''
          Snapshot age above which backup-status reports this profile stale.
          Must exceed the profile's own timerConfig interval.
        '';
      };
```

**Critical:** also add `"maxAgeHours"` to the `moduleKeys` list at `modules/constellation/rustic.nix:57`. `profileType` is `freeformType = types.attrs`, and `profileToml` writes every key not in `moduleKeys` verbatim into `/etc/rustic/<name>.toml`. Omitting this leaks a bogus key into rustic's config file.

- [ ] **Step 4: Register one source per rustic profile**

`profileScripts` at `modules/constellation/rustic.nix:143` currently builds the wrappers inline with `mapAttrsToList`. Refactor it into a reusable single-profile builder so the source command can reference the exact same derivation rather than trusting PATH:

```nix
  mkProfileScript = name: profile:
    pkgs.writeShellScriptBin "rustic-${name}" ''
      set -euo pipefail
      export RUSTIC_CACHE_DIR=${cfg.cacheDir}
      ${optionalString profile.substituteEnv "export RUSTIC_PROFILE_SUBSTITUTE_ENV=true"}
      ${optionalString (profile.environmentFile != null) ''
        set -a
        . ${profile.environmentFile}
        set +a
      ''}
      ${concatStrings (mapAttrsToList (k: v: "export ${k}=${escapeShellArg v}\n")
        (
          if profile.environment == null
          then {}
          else profile.environment
        ))}
      exec ${cfg.package}/bin/rustic -P ${name} "$@"
    '';

  profileScripts = mapAttrsToList mkProfileScript cfg.profiles;
```

Then in the `config` block, next to `constellation.backupNotify.enable`:

```nix
    constellation.backupStatus.enable = mkDefault true;
    constellation.backupStatus.sources = mapAttrsToList (name: profile: {
      inherit name;
      kind = "rustic";
      # rustic prints its [INFO] banner to stderr, so stdout is clean JSON.
      command = "${mkProfileScript name profile}/bin/rustic-${name} snapshots --json";
      inherit (profile) maxAgeHours;
    }) cfg.profiles;
```

- [ ] **Step 5: Give the weekly OVH profile a threshold that matches its schedule**

In `hosts/galactica/backup/rustic-ovh.nix`, inside the `ovh` profile (next to its `timerConfig`):

```nix
      # OnCalendar is "Sun *-*-* 04:30:00" — weekly. 48h would report stale
      # every week; 192h is 8 days, one day of slack past the interval.
      maxAgeHours = 192;
```

- [ ] **Step 6: Build galactica to prove it evaluates**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
just build galactica
```

Expected: builds clean. An error naming `maxAgeHours` in the TOML means Step 3's `moduleKeys` edit was missed.

- [ ] **Step 7: Deploy and verify the red test from Step 1 now passes**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy galactica
ssh galactica.bat-boa.ts.net 'backup-status | jq .'
```

Expected: a JSON array containing an object with `"name": "ovh"`, `"kind": "rustic"`, a real `lastSnapshot`, `"maxAgeHours": 192`, and `"ok": true`.

- [ ] **Step 8: Verify the threshold is genuinely per-source**

```bash
ssh galactica.bat-boa.ts.net 'backup-status | jq -r ".[] | \"\(.name) age=\(.ageHours) max=\(.maxAgeHours) ok=\(.ok)\""'
```

Expected: `ovh` shows `max=192`. Confirm its `ageHours` is under 192 and `ok=true` — a weekly profile sitting at ~70 hours must not be reported stale.

- [ ] **Step 9: Commit**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
git add modules/constellation/backup-status.nix modules/constellation/rustic.nix hosts/galactica/backup/rustic-ovh.nix
git commit -m "feat(modules): add aggregated backup-status with rustic sources"
```

---

### Task 4: `backup-status` sources for backrest

**Files:**
- Modify: `modules/constellation/backrest.nix`

**Interfaces:**
- Consumes: `constellation.backupStatus.sources` from Task 3
- Produces: one `restic`-kind source per entry in `constellation.backrest.repos`

- [ ] **Step 1: Write the failing test — backrest hosts report nothing yet**

```bash
ssh raider.bat-boa.ts.net 'backup-status 2>&1 | head -3'
```

Expected: FAIL with `command not found` (raider runs backrest only, so Task 3 gave it nothing).

- [ ] **Step 2: Add `maxAgeHours` to the repo type**

In `modules/constellation/backrest.nix`, add to `repoType.options` (after `autoUnlock`):

```nix
      maxAgeHours = mkOption {
        type = types.int;
        default = 48;
        description = ''
          Snapshot age above which backup-status reports this repo stale.
          Must exceed the interval of the plans writing to it.
        '';
      };
```

`repoType` is a plain submodule rendered field-by-field in `renderRepo`, so unlike rustic's freeform profile type this needs no exclusion list.

- [ ] **Step 3: Add a per-repo query script and register the sources**

In the `let` block of `modules/constellation/backrest.nix`, alongside `renderRepo`:

```nix
  # A standalone restic invocation per repo, carrying the same credentials the
  # daemon gives restic. rclone-backed repos need rclone on PATH; without it
  # they report an error rather than silently reading as healthy.
  resticQuery = name: repo:
    pkgs.writeShellScript "backup-status-restic-${name}" ''
      set -euo pipefail
      export PATH=${makeBinPath [pkgs.rclone pkgs.openssh]}:$PATH
      export RESTIC_PASSWORD_FILE=${toString repo.passwordFile}
      ${optionalString (repo.envFile != null) ''
        set -a
        . ${toString repo.envFile}
        set +a
      ''}
      ${concatMapStrings (e: "export ${e}\n") repo.env}
      exec ${pkgs.restic}/bin/restic -r ${escapeShellArg repo.uri} snapshots --json
    '';
```

Then in the `config` block, next to the existing `constellation.backupNotify.enable`:

```nix
    constellation.backupStatus.enable = mkDefault true;
    constellation.backupStatus.sources = mapAttrsToList (name: repo: {
      inherit name;
      kind = "restic";
      command = toString (resticQuery name repo);
      inherit (repo) maxAgeHours;
    }) cfg.repos;
```

Confirm `makeBinPath`, `mapAttrsToList`, `concatMapStrings`, `optionalString` and `escapeShellArg` are in scope — the file opens with `with lib;`, which provides all of them.

- [ ] **Step 4: Build all three tier-1 hosts**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
just build raider
just build galactica
just build basestar
```

Expected: all three build clean. galactica must build with **both** rustic and backrest sources registered — that is the collision case the aggregator exists for.

- [ ] **Step 5: Deploy and verify raider**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy raider
ssh raider.bat-boa.ts.net 'backup-status | jq .'
```

Expected: one object with `"name": "storage"`, `"kind": "restic"`, a recent `lastSnapshot`, `"ok": true`.

- [ ] **Step 6: Verify galactica aggregates both kinds**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy galactica
ssh galactica.bat-boa.ts.net 'backup-status | jq -r ".[] | \"\(.kind)\t\(.name)\tok=\(.ok)\""'
```

Expected: at least one `rustic` row (`ovh`) and one or more `restic` rows, all from a single command.

- [ ] **Step 7: Verify a broken source degrades instead of aborting**

```bash
ssh galactica.bat-boa.ts.net 'backup-status | jq -r ".[] | select(.error != null) | \"\(.name): \(.error)\""'
```

Expected: either no output, or named sources with an `error` string — and in the latter case confirm the healthy sources still appear in the same array. A single unreachable repo must never blank the report.

- [ ] **Step 8: Commit**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
git add modules/constellation/backrest.nix
git commit -m "feat(modules): report backrest repo freshness through backup-status"
```

---

### Task 5: `constellation.weeklyDeploy` on galactica

**Files:**
- Create: `modules/constellation/weekly-deploy.nix`
- Modify: `hosts/galactica/configuration.nix`

**Interfaces:**
- Consumes: `backup-status` from Tasks 3–4; `config.constellation.backupNotify.script` (takes two positional args, title and body, and reads `NTFY_BASIC_AUTH_B64` from the environment)
- Produces: `systemd.services.weekly-deploy`, `systemd.timers.weekly-deploy`, and `/var/lib/weekly-deploy/last-run.json`

- [ ] **Step 1: Confirm the calendar spec parses before relying on it**

```bash
ssh galactica.bat-boa.ts.net 'systemd-analyze calendar "Sun *-*-* 06:00:00 UTC"'
```

Expected: a `Next elapse:` line with a UTC-consistent time. If systemd rejects the `UTC` suffix (needs ≥ 252), drop it and set `Timezone` on the timer instead — a silently-local interpretation would drift the run relative to CI.

- [ ] **Step 2: Create the module**

Create `modules/constellation/weekly-deploy.nix`. Use `--impure` or not per Task 1's recorded finding:

```nix
# Constellation weekly-deploy module
#
# galactica pulls master and deploys tier-1 once a week, then reports. It must
# never build: NIX_CONFIG="max-jobs = 0" makes local compilation impossible, so
# a closure missing from attic is a loud error instead of a compile that OOMs
# the host running the media stack.
#
# The contract with CI: a fresh flake.lock on master means tier-1 built clean,
# because update.yml gates its commit on exactly those three hosts. This module
# therefore never has to reason about CI status for correctness — only to avoid
# racing a commit whose closures are still uploading.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.weeklyDeploy;

  deployScript = pkgs.writeShellScriptBin "weekly-deploy" ''
    set -uo pipefail
    export PATH=${makeBinPath [
      pkgs.git
      pkgs.colmena
      pkgs.openssh
      pkgs.jq
      pkgs.curl
      pkgs.nix
      pkgs.coreutils
      pkgs.gnused
    ]}:$PATH

    STATE=${cfg.stateDir}
    REPO="$STATE/nixos"
    HOSTS="${concatStringsSep " " cfg.hosts}"

    notify() {
      ${config.constellation.backupNotify.script} "$1" "$2" || true
    }

    mkdir -p "$STATE"

    if [ ! -d "$REPO/.git" ]; then
      git clone ${escapeShellArg cfg.repoUrl} "$REPO" || {
        notify "Weekly deploy failed on ${config.networking.hostName}" "git clone failed"
        exit 1
      }
    fi

    cd "$REPO"
    git fetch --prune origin || {
      notify "Weekly deploy failed on ${config.networking.hostName}" "git fetch failed"
      exit 1
    }
    git reset --hard origin/master
    SHA=$(git rev-parse HEAD)

    # Precondition: only deploy a commit CI has finished building and pushing.
    # Without this, a commit whose closures are still uploading fails every node
    # on max-jobs=0 and reads as a fleet outage rather than a timing artifact.
    CONCL=$(curl -sS --max-time 30 \
      "https://api.github.com/repos/${cfg.repoSlug}/actions/runs?head_sha=$SHA&per_page=20" \
      | jq -r '[.workflow_runs[] | select(.name=="Build & Cache")]
               | sort_by(.created_at) | last | .conclusion // "none"' 2>/dev/null || echo "none")

    if [ "$CONCL" != "success" ]; then
      notify "Weekly deploy skipped on ${config.networking.hostName}" \
        "master $SHA is not green (Build & Cache: $CONCL). Nothing was deployed."
      exit 0
    fi

    # Reachability probe that doubles as known_hosts seeding: colmena's ssh
    # would otherwise fail on an unknown host key. Tailscale is the trust
    # boundary here — these hosts are already tailnet-authenticated.
    for h in $HOSTS; do
      ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        "root@$h.bat-boa.ts.net" true 2>/dev/null || true
    done

    export NIX_CONFIG="max-jobs = 0"
    colmena apply ${optionalString cfg.impureEval "--impure "}--on @tier1 \
      >"$STATE/last-deploy.log" 2>&1 || true

    for h in $HOSTS; do
      ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$h.bat-boa.ts.net" \
        systemctl start multi-user.target 2>/dev/null || true
    done

    RESULTS=""
    PROBLEMS=0
    SUMMARY=""

    for h in $HOSTS; do
      TARGET="root@$h.bat-boa.ts.net"
      GEN=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
        'readlink -f /run/current-system' 2>/dev/null || echo "unreachable")
      FAILED=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
        'systemctl --failed --no-legend | awk "{print \$1}" | paste -sd, -' 2>/dev/null || echo "?")
      BACKUPS=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
        'backup-status' 2>/dev/null || echo "[]")

      STALE=$(printf '%s' "$BACKUPS" \
        | jq -r '[.[] | select(.ok | not) | .name] | join(",")' 2>/dev/null || echo "?")

      HOST_BAD=0
      [ "$GEN" = "unreachable" ] && HOST_BAD=1
      [ -n "$FAILED" ] && [ "$FAILED" != "?" ] && HOST_BAD=1
      [ -n "$STALE" ] && [ "$STALE" != "?" ] && HOST_BAD=1
      [ "$HOST_BAD" -eq 1 ] && PROBLEMS=$((PROBLEMS + 1))

      if [ "$HOST_BAD" -eq 1 ]; then
        SUMMARY="$SUMMARY$h: FAILED=[''${FAILED:-none}] STALE=[''${STALE:-none}] GEN=$GEN"$'\n'
      else
        SUMMARY="$SUMMARY$h: ok"$'\n'
      fi

      RESULTS="$RESULTS$(jq -nc \
        --arg host "$h" --arg gen "$GEN" --arg failed "$FAILED" --arg stale "$STALE" \
        --argjson backups "$(printf '%s' "$BACKUPS" | jq -c . 2>/dev/null || echo '[]')" \
        '{host:$host,generation:$gen,failedUnits:$failed,staleBackups:$stale,backups:$backups}')"
    done

    printf '%s' "$RESULTS" | jq -s \
      --arg sha "$SHA" --arg when "$(date -Is)" \
      '{commit:$sha,ranAt:$when,hosts:.}' > "$STATE/last-run.json"

    TOTAL=$(printf '%s' "$HOSTS" | wc -w)
    OK=$((TOTAL - PROBLEMS))

    if [ "$PROBLEMS" -gt 0 ]; then
      notify "ACTION NEEDED - weekly deploy: $OK/$TOTAL healthy" "$SUMMARY"
    else
      notify "Weekly deploy: $OK/$TOTAL healthy" "$SUMMARY"
    fi

    exit 0
  '';
in {
  options.constellation.weeklyDeploy = {
    enable = mkEnableOption "weekly tier-1 update, deploy and health report";

    hosts = mkOption {
      type = types.listOf types.str;
      default = ["galactica" "basestar" "raider"];
      description = ''
        Hosts included in the verification sweep. The deploy itself targets the
        @tier1 colmena tag, which is generated from flake-modules/hosts.nix; keep
        this list in sync or the sweep silently skips a host the deploy touched.
      '';
    };

    schedule = mkOption {
      type = types.str;
      default = "Sun *-*-* 06:00:00 UTC";
      description = "OnCalendar spec. Must land after the Sunday 00:00 UTC CI run.";
    };

    repoUrl = mkOption {
      type = types.str;
      default = "https://github.com/arsfeld/nixos.git";
      description = "Public clone URL. https so the unit needs no credentials.";
    };

    repoSlug = mkOption {
      type = types.str;
      default = "arsfeld/nixos";
      description = "owner/repo, used for the GitHub Actions status query.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/weekly-deploy";
      description = "Machine-owned checkout, logs and last-run.json. Holds no user data.";
    };

    impureEval = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Pass --impure to colmena, matching `just deploy`. Set false if the
        pre-flight check showed impure evaluation yields different derivations
        than CI built, which would break substitution-only deploys.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.weekly-deploy = {
      description = "Weekly tier-1 update, deploy and health report";
      after = ["network-online.target" "tailscaled.service"];
      wants = ["network-online.target"];

      # This unit deploys the host it runs on. Without these, activation
      # restarts the job mid-flight and the report never gets sent.
      restartIfChanged = false;
      stopIfChanged = false;

      onFailure = ["backup-notify@weekly-deploy.service"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${deployScript}/bin/weekly-deploy";
        EnvironmentFile = config.constellation.backupNotify.envFile;
        # A runaway evaluation dies in its own cgroup instead of taking the
        # media stack down with it.
        MemoryMax = "12G";
        Nice = 10;
        TimeoutStartSec = "3h";
      };
    };

    systemd.timers.weekly-deploy = {
      description = "Timer for weekly-deploy";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = 600;
      };
    };

    systemd.tmpfiles.rules = ["d ${cfg.stateDir} 0700 root root -"];
  };
}
```

- [ ] **Step 3: Enable it on galactica**

In `hosts/galactica/configuration.nix`, alongside the other `constellation.*` enables:

```nix
  # galactica is the only always-on x86 host with Tailscale SSH to the rest of
  # tier-1, and it never builds here (max-jobs = 0), so the weekly deploy costs
  # it a download and an activation.
  constellation.weeklyDeploy.enable = true;
```

- [ ] **Step 4: Build and deploy**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
just build galactica
nix develop -c just deploy galactica
```

Expected: builds and deploys clean.

- [ ] **Step 5: Verify the timer is scheduled**

```bash
ssh galactica.bat-boa.ts.net 'systemctl list-timers weekly-deploy --no-pager'
```

Expected: one row with a `NEXT` on the coming Sunday.

- [ ] **Step 6: Run it out-of-band and confirm nothing compiles**

```bash
ssh galactica.bat-boa.ts.net 'sudo systemctl start weekly-deploy && sudo journalctl -u weekly-deploy -n 60 --no-pager'
```

Expected: completes without `building '/nix/store/...drv'` lines in the journal. Any such line means `max-jobs = 0` is not reaching nix and must be fixed before this ships — that guarantee is the whole reason galactica is the deployer.

- [ ] **Step 7: Verify the report**

```bash
ssh galactica.bat-boa.ts.net 'sudo jq . /var/lib/weekly-deploy/last-run.json'
```

Expected: `commit`, `ranAt`, and a `hosts` array of three entries, each with `generation`, `failedUnits`, `staleBackups` and a populated `backups` array. Confirm an ntfy message arrived on the `backups` topic.

- [ ] **Step 8: Verify the not-green skip path**

```bash
ssh galactica.bat-boa.ts.net \
  'cd /var/lib/weekly-deploy/nixos && sudo git reset --hard HEAD~5 && sudo systemctl start weekly-deploy; \
   sudo journalctl -u weekly-deploy -n 20 --no-pager'
```

Expected: either a skip notification naming the SHA, or a normal run if that older commit also built green. Then restore:

```bash
ssh galactica.bat-boa.ts.net 'cd /var/lib/weekly-deploy/nixos && sudo git fetch origin && sudo git reset --hard origin/master'
```

- [ ] **Step 9: Commit**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
git add modules/constellation/weekly-deploy.nix hosts/galactica/configuration.nix
git commit -m "feat(galactica): deploy tier-1 weekly without building locally"
```

---

### Task 6: Cleanup — declarative Tailscale SSH, neutral notify title, delete the routine

**Files:**
- Modify: `modules/constellation/common.nix`
- Modify: `modules/constellation/backup-notify.nix`

**Interfaces:**
- Consumes: nothing
- Produces: nothing consumed downstream

- [ ] **Step 1: Record the current state before changing it**

```bash
for h in galactica basestar raider; do
  echo -n "$h: "
  ssh "$h.bat-boa.ts.net" 'tailscale status --json | jq -r ".Self.Capabilities // [] | index(\"ssh\") | if . then \"ssh-enabled\" else \"no-ssh-cap\" end"' 2>/dev/null \
    || echo "query failed"
done
```

This is a before/after reference. Tailscale SSH is currently imperative state — the point of this task is that it stops being.

- [ ] **Step 2: Declare Tailscale SSH in `common.nix`**

Replace `services.tailscale.enable = true;` at `modules/constellation/common.nix:202` with:

```nix
    services.tailscale = {
      enable = true;
      # Tailscale SSH is what lets galactica's weekly-deploy reach root on the
      # other tier-1 hosts with no key material anywhere. It was imperative
      # state until now, so a host re-auth or reinstall could silently break
      # the deployer. extraSetFlags reapplies on every activation, unlike
      # extraUpFlags which only applies to the initial `tailscale up`.
      # Who may actually use it is governed by the tailnet ACL, out of repo.
      extraSetFlags = ["--ssh"];
    };
```

- [ ] **Step 3: Make the notify title neutral**

In `modules/constellation/backup-notify.nix`, change the templated unit's `ExecStart` (line 70) from the backup-specific title to:

```nix
        ExecStart = ''${cfg.script} "${config.networking.hostName}: %i failed" "systemd unit %i failed on ${config.networking.hostName}. Run: journalctl -u %i -n 100 --no-pager"'';
```

`weekly-deploy` now points `OnFailure` here too, and the module already served two unrelated callers (rustic and backrest), so the title was never carrying backup-specific meaning.

- [ ] **Step 4: Build every tier-1 host — `common.nix` touches all of them**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
just build galactica
just build basestar
just build raider
```

Expected: all three build clean.

- [ ] **Step 5: Deploy and confirm SSH still works after the change**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy galactica basestar
nix develop -c just deploy raider
ssh galactica.bat-boa.ts.net 'sudo ssh -o BatchMode=yes -o ConnectTimeout=10 root@raider.bat-boa.ts.net hostname'
```

Expected: prints `raider`. **This is the critical regression check** — if `extraSetFlags` were wrong it could disable the very SSH path the deployer needs. If it fails, revert this task immediately; Tasks 1–5 do not depend on it.

- [ ] **Step 6: Commit**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
git add modules/constellation/common.nix modules/constellation/backup-notify.nix
git commit -m "fix(modules): declare tailscale ssh and neutralize the notify title"
git push origin master
```

- [ ] **Step 7: Delete the dead Claude routine**

The routine `trig_01WR4gHeR7Hw8oSLFNsguNaL` ("Weekly flake update + deploy tier 1") has never completed a single run — every Sunday since 2026-06-05 it landed in a cloud sandbox with no nix, no ssh and no Tailscale, and exited in about a minute. galactica now owns this job.

It is not managed from this repo, so nothing in git changes. Deletion is an outward-facing
action on the user's account — **confirm with them first**, then delete it through the
routine tooling (the `schedule` skill, or a `RemoteTrigger` call with
`action: "update"` and `enabled: false` to disable it non-destructively first).

Disabling before deleting is the safer order: if anything in Tasks 1–5 turns out to need
rework, a disabled routine can be re-enabled, while a deleted one has to be rebuilt from
the prompt recorded in this plan's spec.

- [ ] **Step 8: Update the repo docs**

Add to `CLAUDE.md` under "Key Commands", after the deployment section:

```markdown
### Weekly Automation

- **GitHub `Weekly Update`** (Sun 00:00 UTC): `nix flake update`, builds tier-1, commits
  `flake.lock` to master. Gated on tier-1 only — a broken octopi will not block the lock.
- **galactica `weekly-deploy`** (Sun 06:00 UTC): pulls master, deploys `@tier1` with
  `max-jobs = 0` so it never builds, verifies failed units and backup freshness over
  Tailscale SSH, and posts one ntfy summary. State in `/var/lib/weekly-deploy/`.
  Run it early with `sudo systemctl start weekly-deploy`.
```

```bash
cd /home/arosenfeld/Code/nixos
git add CLAUDE.md
git commit -m "docs(modules): document the weekly update and deploy automation"
git push origin master
```

---

## Post-Implementation Verification

Run after all six tasks land, then again after the first real Sunday:

- [ ] `gh run list --workflow=update.yml --limit 1` shows a green run building exactly three hosts.
- [ ] `git log --oneline -1 -- flake.lock` shows a recent `chore: update flake inputs` commit authored by `github-actions[bot]`.
- [ ] `ssh galactica.bat-boa.ts.net 'systemctl list-timers weekly-deploy --no-pager'` shows the next elapse.
- [ ] `ssh galactica.bat-boa.ts.net 'sudo jq -r ".hosts[] | \"\(.host): \(.staleBackups)\"" /var/lib/weekly-deploy/last-run.json'` reports no stale backups.
- [ ] An ntfy message arrived on `ntfy.arsfeld.one/backups` for the Sunday run.
- [ ] `ssh galactica.bat-boa.ts.net 'sudo journalctl -u weekly-deploy --since "1 week ago" | grep -c "building "'` returns `0`.
