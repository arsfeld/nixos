# OVH Cold Archive via rustic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace galactica's €10.90/month Hetzner Storage Box with a rustic-driven hot/cold repository on OVHcloud Cold Archive v2 (~€4/month), leaving Backrest and every other host untouched.

**Architecture:** A new `constellation.rustic` module resurrects the retired `modules/rustic.nix`, rendering one `/etc/rustic/<profile>.toml` per profile plus a backup unit, a separate monthly prune unit, and a manual wrapper script. galactica gets one profile, `ovh`, whose cold repo is an OVH S3 bucket with `default_storage_class = "DEEP_ARCHIVE"` and whose hot repo is a Standard bucket in the same region; restores warm packs back off tape via two `aws s3api` helper scripts wired to rustic's `warm-up-command` / `warm-up-wait-command`. Backrest keeps the warm tiers (local NAS, pegasus REST); the two orchestrators never touch the same repo. A third new module, `constellation.backupNotify`, factors Backrest's inline ntfy curl into one shared script that both orchestrators call.

**Tech Stack:** NixOS modules (haumea auto-discovery), rustic 0.11.3 (`pkgs-unstable`), opendal S3 backend, `pkgs.formats.toml`, systemd oneshot units + timers, sops-nix, awscli2 + jq (restore path only), `ovhcloud-cli` (resource provisioning), Colmena deploy.

**Source spec:** `docs/superpowers/specs/2026-07-27-ovh-cold-archive-rustic-design.md`

## Global Constraints

- **Commit straight to master.** No feature branches, no worktrees, in this repo.
- **Conventional commits**, scope `galactica`, `modules`, `secrets`, or `docs`. Never mention Claude in messages or author.
- Build with `nix develop -c nix build ...` and **read the last line for the error count** before claiming success.
- `just fmt` (alejandra) before every commit; `format.yml` fails CI otherwise.
- **No per-app firewall rules.** Nothing in this plan opens a port.
- sops is fully automated — use `sops set FILE '["key"]' '"value"'`, never interactive editing.
- **Never destroy data without explicit operator confirmation at the time.** Tasks 10 and 11 both delete things; both are gated.
- OVH resources are provisioned with `nix run nixpkgs#ovhcloud-cli -- …`, already authenticated on this workstation. It is a **billable** API — creating a bucket or a user is an outward-facing action, so Task 3 Step 2 is confirmation-gated. Its `--init-file` / `--editor` modes need a TTY and fail under an agent; use plain flags.
- OVH region is `eu-west-par` **only**. Storage class string is `DEEP_ARCHIVE`. Minimum storage duration **180 days**; early delete bills `(180 − days used) × price`.
- Lifecycle transitions *into* Cold Archive are not supported — objects must be written directly in the class.
- rustic profile files live at `/etc/rustic/<profile>.toml` (confirmed search order: `$HOME/.config/rustic/`, `/etc/rustic/`, `./`).

---

## Verified before writing this plan

Everything below was run against rustic 0.11.3 and (where noted) OVH's live endpoint. Read this section before Task 1 — it corrects three claims in the spec, resolves two of its four open questions, and surfaces one hazard the spec did not know about.

**1. `pkgs.rustic` on stable is 0.11.2, not 0.11.3.** `pkgs-unstable.rustic` is 0.11.3. The module defaults to `pkgs-unstable.rustic`, following the precedent in `modules/constellation/backrest.nix:38-40`.

**2. The exclude translation is 1:1, empirically.** A scratch tree with `mnt/storage/{media,backups,homes,keep}` and `home/alice/{.cache,torrents,Documents}` gave identical results from both tools:

```
rustic backup --dry-run --glob '!…/mnt/storage/backups' --glob '!…/mnt/storage/media' \
  --glob '!…/mnt/storage/homes' --glob '!…/home/*/.cache' --glob '!…/home/*/torrents' …
  → total_files_processed=2  total_bytes_processed=12   (baseline without globs: 7 / 42)

restic backup --dry-run --exclude … (same five paths)
  → total_files_processed=2  total_bytes_processed=12
```

Absolute anchored paths and `*`-segment patterns both translate by prefixing `!`. **Caveat found:** if a *source* path is itself an excluded path, the exclude does not apply — `backup --glob '!…/media' …/media` backed the directory up. Our sources are `/`, `/home`, `/mnt/storage`, never an excluded path, so this does not bite; do not "simplify" the gate by pointing a dry-run directly at an excluded directory.

**3. The spec's "roughly 60 patterns" is wrong — it is 20.** `localSystemExcludes` is out of scope (local plan, unchanged). In scope: `systemExcludes` (14 patterns) and `userExcludes` (6). All 20 are plain anchored paths except `/home/*/.cache` and `/home/*/torrents`, both covered by the verification above.

**4. `%id` with `warm-up-batch > 1` — spec open question, resolved.** rustic substitutes `%id` with **one shell argument containing space-separated pack ids**. Proof: a probe script printing `$#` reported `ARGC=1` on every invocation, while `echo GOTPACK %id` at `--warm-up-batch 3` produced a line carrying 11 ids. The helper scripts therefore loop over unquoted `$1`, which is correct at any batch size. `warm-up-batch = 1` remains the configured value.

**5. Credentials never enter the Nix store.** rustic's `--profile-substitute-env` / `RUSTIC_PROFILE_SUBSTITUTE_ENV=true` expands `$VAR` and `${VAR}` inside the profile (verified; `{{VAR}}` and `%VAR%` are *not* expanded). The profile carries `access_key_id = "${AWS_ACCESS_KEY_ID}"`, and the value arrives from the sops `ovh-s3-env` `EnvironmentFile`. Using the `AWS_*` names means the same secret file also feeds `awscli2` in the restore scripts.

**6. The endpoint is real, and `access_key_id`/`secret_access_key` are the right opendal keys — spec open question, resolved.** A probe with deliberately bogus credentials reached `https://s3.eu-west-par.io.cloud.ovh.net` and got a signed-request rejection:

```
uri: https://s3.eu-west-par.io.cloud.ovh.net/<bucket>?list-type=2&prefix=keys%2F
status: 403 … S3Error { code: "SignatureDoesNotMatch", … request_id: "tx73f2…" }
```

`SignatureDoesNotMatch` (rather than a missing-credential or DNS error) proves the option names were consumed and the request was signed. Path-style addressing, `x-amz-request-id` present.

**⚠ Also learned from that probe: opendal silently ignores unknown option keys.** A `totally_bogus_key = "zzz"` in `[repository.options]` produced no warning. A typo in `default_storage_class` would therefore write ~2 TB at the Standard rate with no error anywhere. **Task 5 exists specifically to catch this before the seed.**

**7. Passing sources on the command line still applies the profile's globs.** This is what makes Task 7's split seed safe, and it was not obvious. With two `[[backup.snapshots]]` entries configured, `rustic -P … backup /home /mnt/storage` matched the *user* entry — same file count, and the emitted snapshot carried `label: "user"`. It does not silently fall back to the first entry's globs, and it does not drop the globs. Sources given on the CLI must still match a configured entry exactly; `/` matches the system entry, `/home /mnt/storage` matches the user entry.

**8. `pkgs.formats.toml` renders the profile exactly as rustic wants it, and rustic accepts it.** The host profile in Task 4 was rendered through `pkgs.formats.toml` and fed to `rustic show-config`: `[[backup.snapshots]]` array-of-tables, `[repository.options-cold]` / `[repository.options-hot]` sub-tables, and `${AWS_ACCESS_KEY_ID}` surviving unexpanded, all correct. One gotcha found doing it: `global.log-file` points at `/var/log/rustic/`, so a **non-root** `rustic show-config` dies with `config error: Permission denied` before validating anything. Task 4's check script rewrites that one line; the units run as root and are unaffected.

**9. Miscellaneous, all verified:** pack key layout is `data/<first-2-hex>/<full-64-hex-id>`; `rustic forget --prune --keep-pack <DURATION>` accepts the full PRUNE OPTIONS set; the forget CLI flag is `--filter-label` (singular) while the config key is `filter-labels` (plural); `--repack-cacheable-only` already defaults to `true` on a hot/cold repository; `password-file` tolerates a trailing newline (so a plain sops string works); `backup --json` emits top-level `label`, `paths`, `hostname`, `time` and `summary`; a wrong password exits non-zero with error code `C002`; `sops set FILE '["key"]' '"value"'` and `sops unset` both work non-interactively, including `\n`-bearing multi-line values.

## Deviations from the spec

**A. No bandwidth limiting during the seed.** The spec says "bandwidth-limited so it does not saturate the household link". rustic has no rate-limit option (checked `backup --help`: nothing matching limit/throttle/bandwidth/rate), and the router's CAKE shaper is configured for `bandwidth = 2250` Mbit/s (`hosts/router/configuration.nix:107-116`) against a link the spec measured at **157.94 Mbit/s up** — the shaper sits far above the real bottleneck, so it never engages and provides no protection here. Task 7 instead splits the seed (system snapshot first, then user), runs it niced and idle-I/O in a detached scope, and documents an explicit `tc tbf` cap as the opt-in lever if the household notices. The 2250-vs-158 mismatch is a real router misconfiguration but is out of scope for this plan.

**B. The parity gate runs against the real OVH repo, not a scratch repo.** `--dry-run` writes nothing, ingress and API calls are free, and running it through `rustic -P ovh` tests the *actual rendered profile* — including the glob lists, which is the whole point. This requires the buckets to exist first, which matches the spec's own cutover ordering (step 1 then step 2).

**C. `prune = false` is omitted from `[forget]`.** `false` is already the default, the backup unit never invokes `forget`, and leaving a config value that the prune unit's `--prune` flag then overrides is a trap for the next reader. The keep ladder stays in `[forget]`; `--prune --keep-pack 180d` stays on the prune unit's `ExecStart`.

---

## File Structure

| File | Responsibility |
|---|---|
| **Create** `modules/constellation/backup-notify.nix` | `constellation.backupNotify`: one shared ntfy POST script + a `backup-notify@.service` template unit. Consumed by both orchestrators. |
| **Modify** `modules/constellation/backrest.nix:78-91` | Replace the inline curl in `defaultFailureHook` with a call to the shared script; enable `backupNotify`. |
| **Create** `modules/constellation/rustic.nix` | `constellation.rustic`: profile → TOML, backup unit, prune unit, timers, wrapper script. Host-agnostic. |
| **Create** `hosts/galactica/backup/rustic-ovh.nix` | The `ovh` profile: buckets, endpoint, glob lists, retention, warm-up scripts, sops secrets. All OVH-specific knowledge lives here. |
| **Modify** `hosts/galactica/backup/default.nix` | Import the new host file. |
| **Modify** `hosts/galactica/backup/backrest-client.nix:82-140` | Task 10: drop the `hetzner` repo, its two plans, and its two sops secrets. |
| **Modify** `secrets/sops/galactica.yaml` | Add `rustic-ovh-password`, `ovh-s3-env`; Task 10 removes the two hetzner secrets. |
| **Modify** `docs/architecture/backup.md`, `docs/hosts/storage.md` | Task 10: topology, repo table, secrets list. |

---

## Task 1: Shared ntfy notification helper

Factors Backrest's inline curl into one script so rustic's `OnFailure=` can reuse it. Deliverable: Backrest's rendered `config.json` calls the shared script and a manual invocation delivers a real ntfy message.

**Files:**
- Create: `modules/constellation/backup-notify.nix`
- Modify: `modules/constellation/backrest.nix:78-91`
- Test: manual — `nix build` + `jq` on the rendered config template + a live ntfy POST

**Interfaces:**
- Produces: `config.constellation.backupNotify.script` — a store path to an executable taking exactly two positional args, `script <title> <body>`. Reads `NTFY_BASIC_AUTH_B64` from the environment (fails if unset). Task 2 references it as `OnFailure` targets `backup-notify@<unit>.service`.
- Produces: `systemd.services."backup-notify@"` — templated oneshot; `%i` is the failed unit's name without the `.service` suffix.
- Consumes: `config.sops.secrets."ntfy-publisher-env".path`, already declared on galactica in `hosts/galactica/services/ntfy.nix:25-29`.

- [ ] **Step 1: Write the failing check**

Throwaway scripts in this plan live in `/tmp/rustic-plan-checks/`. Create it and save this as `/tmp/rustic-plan-checks/check-notify.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/arosenfeld/Code/nixos

script=$(nix eval --raw .#nixosConfigurations.galactica.config.constellation.backupNotify.script)
echo "script = $script"
[ -x "$script" ] || { echo "FAIL: script is not executable"; exit 1; }

# The POST must live in the shared script, not inline in Backrest's hook.
grep -q 'curl' "$script" || { echo "FAIL: shared script does not POST"; exit 1; }

echo "PASS"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash /tmp/rustic-plan-checks/check-notify.sh`
Expected: FAIL — `error: attribute 'backupNotify' missing`

- [ ] **Step 3: Create the module**

Create `modules/constellation/backup-notify.nix`:

```nix
# Constellation backup-notify module
#
# One ntfy POST, two callers.
#
#   - Backrest calls `script` from a plan hook's actionCommand, because it
#     needs Backrest's own template expansion ({{.Repo.Id}} etc.) and so
#     cannot be a systemd unit.
#   - rustic's units point OnFailure= at backup-notify@<unit>.service, the
#     templated unit defined here.
#
# Same credential, same topic, one feed from the operator's side.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backupNotify;

  # set -u is deliberate: an unset NTFY_BASIC_AUTH_B64 means the caller
  # forgot its EnvironmentFile, and a silent unauthenticated POST would
  # look like a working notification path until the day it matters.
  notifyScript = pkgs.writeShellScript "backup-notify" ''
    set -euo pipefail
    title="$1"
    body="$2"
    exec ${pkgs.curl}/bin/curl -sS --fail-with-body -X POST \
      -H "Authorization: Basic $NTFY_BASIC_AUTH_B64" \
      -H "Title: $title" \
      -H "Tags: floppy_disk,warning" \
      --data-binary "$body" \
      ${cfg.ntfyUrl}
  '';
in {
  options.constellation.backupNotify = {
    enable = mkEnableOption "shared ntfy notifier for backup orchestrators";

    ntfyUrl = mkOption {
      type = types.str;
      default = "https://ntfy.arsfeld.one/backups";
      description = "ntfy topic URL for backup failure notifications.";
    };

    envFile = mkOption {
      type = types.path;
      default = config.sops.secrets."ntfy-publisher-env".path;
      description = "EnvironmentFile providing NTFY_BASIC_AUTH_B64.";
    };

    script = mkOption {
      type = types.path;
      default = notifyScript;
      readOnly = true;
      description = ''
        Executable taking two positional arguments: title and body.
        Reads NTFY_BASIC_AUTH_B64 from the environment.
      '';
    };
  };

  config = mkIf cfg.enable {
    # %i is the failed unit's name without the .service suffix; callers
    # instantiate this as backup-notify@<unit>.service from OnFailure=.
    systemd.services."backup-notify@" = {
      description = "ntfy notification for failed backup unit %i";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = cfg.envFile;
        ExecStart = ''${cfg.script} "Backup failed on ${config.networking.hostName}: %i" "systemd unit %i failed on ${config.networking.hostName}. Run: journalctl -u %i -n 100 --no-pager"'';
      };
    };
  };
}
```

- [ ] **Step 4: Point Backrest at the shared script**

In `modules/constellation/backrest.nix`, replace the `defaultFailureHook` block (lines 78-91) with:

```nix
  defaultFailureHook = {
    conditions = ["CONDITION_ANY_ERROR" "CONDITION_SNAPSHOT_ERROR"];
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

Single quotes around the template arguments are preserved from the original on purpose — `{{.Error}}` is attacker-adjacent free text and the previous form had the same containment.

Update the comment above it (lines 72-77) to read:

```nix
  # Module-level default failure hook. Uses actionCommand (shell) instead
  # of actionWebhook so the ntfy publisher credential stays in
  # EnvironmentFile and never appears in the rendered config.json (the UI
  # renders hook configurations verbatim).
  #
  # The POST itself lives in constellation.backupNotify so rustic's cold-tier
  # units share exactly one implementation. Backrest cannot use the templated
  # backup-notify@.service — it needs Backrest's own {{...}} expansion, which
  # only happens inside an actionCommand.
```

Then, inside `config = mkIf cfg.enable { … }` (after the `sops.secrets."restic-password"` block at line 357-359), add:

```nix
    constellation.backupNotify.enable = mkDefault true;
```

- [ ] **Step 5: Format and build**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just fmt
nix develop -c nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```

Expected: build succeeds. **Read the last line for the error count.**

- [ ] **Step 6: Re-run the check**

Run: `bash /tmp/rustic-plan-checks/check-notify.sh`
Expected: prints a `/nix/store/…-backup-notify` path and `PASS`.

- [ ] **Step 7: Confirm Backrest's rendered config still carries the hook**

```bash
cd /home/arosenfeld/Code/nixos
nix eval --raw --impure --expr '
  let f = builtins.getFlake (toString /home/arosenfeld/Code/nixos);
      c = f.nixosConfigurations.galactica.config;
  in builtins.toJSON c.constellation.backrest.plans
' | jq -r '.["local-system"].hooks // "uses module default (null)"'
```

Expected: `uses module default (null)` — per-plan hooks are unset, so the module default applies. This confirms the refactor did not accidentally add per-plan hooks.

- [ ] **Step 8: Deploy and prove a live notification**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy galactica
script=$(nix eval --raw .#nixosConfigurations.galactica.config.constellation.backupNotify.script)
ssh galactica.bat-boa.ts.net "sudo bash -c '
  set -a; . /run/secrets/ntfy-publisher-env; set +a
  $script \"backup-notify smoke test\" \"Task 1 verification, ignore.\"
'"
```

Expected: exit 0, and the message appears at `https://ntfy.arsfeld.one/backups`.

- [ ] **Step 9: Prove the templated unit resolves**

```bash
ssh galactica.bat-boa.ts.net \
  'systemctl cat "backup-notify@rustic-ovh.service" | head -20'
```

Expected: shows `Description=ntfy notification for failed backup unit rustic-ovh` and an `ExecStart` whose `%i` has become `rustic-ovh`.

- [ ] **Step 10: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add modules/constellation/backup-notify.nix modules/constellation/backrest.nix
git commit -m "refactor(modules): factor backup ntfy POST into constellation.backupNotify"
```

---

## Task 2: `constellation.rustic` module

Host-agnostic module: profile → `/etc/rustic/<name>.toml`, one backup unit, one prune unit, optional timers, a wrapper script. No host enables it yet, so galactica's build must be byte-identical except for the new module file being present.

**Files:**
- Create: `modules/constellation/rustic.nix`
- Test: manual — `nix build`, then `rustic show-config` against the rendered TOML (Task 4 supplies a profile to render)

**Interfaces:**
- Consumes: `config.constellation.backupNotify.script` (Task 1), via `OnFailure` targets.
- Produces: `constellation.rustic.enable` (bool) and `constellation.rustic.profiles.<name>`, a **freeform** submodule. Every attribute except the six module-owned keys below is serialised verbatim into the profile TOML.
  - `timerConfig` : `nullOr attrs` — systemd timer for the backup unit. `null` (default) means no timer.
  - `pruneTimerConfig` : `nullOr attrs` — systemd timer for the prune unit. `null` (default) means no timer.
  - `pruneArgs` : `listOf str`, default `["--prune"]` — appended to `rustic -P <name> forget`.
  - `environment` : `nullOr (attrsOf str)`, default `null`.
  - `environmentFile` : `nullOr str`, default `null`.
  - `substituteEnv` : `bool`, default `false` — sets `RUSTIC_PROFILE_SUBSTITUTE_ENV=true`.
- Produces units `rustic-<name>.service`, `rustic-<name>.timer`, `rustic-<name>-prune.service`, `rustic-<name>-prune.timer`, and a `rustic-<name>` binary on `PATH`.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/rustic-plan-checks/check-rustic-module.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/arosenfeld/Code/nixos
nix eval .#nixosConfigurations.galactica.options.constellation.rustic.enable.type.description --raw
echo
echo "PASS: option exists"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash /tmp/rustic-plan-checks/check-rustic-module.sh`
Expected: FAIL — `error: attribute 'rustic' missing`

- [ ] **Step 3: Create the module**

Create `modules/constellation/rustic.nix`:

```nix
# Constellation rustic module
#
# Resurrected from modules/rustic.nix, retired in 362b751 ("refactor(modules):
# retire rustic and refresh backup docs"), and reshaped to constellation
# conventions.
#
# rustic exists *alongside* Backrest, not instead of it. Backrest wraps restic,
# and restic has no hot/cold repository concept, so a cold-storage tier (OVH
# Cold Archive, i.e. tape) cannot live inside Backrest:
#
#   Backrest owns the warm tiers (local NAS, pegasus REST).
#   rustic   owns the cold tier  (OVH).
#
# They never touch the same repo.
#
# Five deliberate changes from the retired version:
#   - Prune is a separate unit on its own timer. The old module only ran
#     `backup`. Pruning a cold repo weekly is wrong; it is monthly here.
#   - IOSchedulingClass = "idle", restoring the per-plan ionice that the
#     Backrest migration had to drop (see backrest-client.nix:11-15). rustic
#     gets its own unit, so it is free to reinstate it.
#   - OnFailure into the shared ntfy path. The retired module had no failure
#     reporting at all.
#   - No repo password of its own is assumed: the profile supplies
#     password-file, so a host can scope its archive password separately from
#     the fleet-wide restic-password in common.yaml.
#   - No `init` in ExecStartPre. The old module ran it before every backup with
#     a `-` prefix, so a misconfigured repo would be silently created rather
#     than reported. Init once, by hand.
#
# Each profile generates:
#   /etc/rustic/<name>.toml         rendered from the freeform attrs
#   rustic-<name>.service           backup, oneshot
#   rustic-<name>.timer             iff timerConfig != null
#   rustic-<name>-prune.service     forget + prune, oneshot
#   rustic-<name>-prune.timer       iff pruneTimerConfig != null
#   rustic-<name>                   wrapper on PATH for manual invocation
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib; let
  cfg = config.constellation.rustic;

  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };

  tomlFormat = pkgs.formats.toml {};

  # Attributes this module consumes rather than passing through to the TOML.
  # rustic rejects nothing and opendal silently ignores unknown option keys,
  # so anything left in here by accident would be invisible, not an error.
  moduleKeys = [
    "timerConfig"
    "pruneTimerConfig"
    "pruneArgs"
    "environment"
    "environmentFile"
    "substituteEnv"
  ];

  profileToml = name: profile:
    tomlFormat.generate "rustic-${name}.toml" (
      recursiveUpdate
      {global.log-file = "${cfg.logDir}/${name}.log";}
      (removeAttrs profile moduleKeys)
    );

  profileEnv = profile:
    {
      RUSTIC_CACHE_DIR = cfg.cacheDir;
    }
    // optionalAttrs profile.substituteEnv {
      RUSTIC_PROFILE_SUBSTITUTE_ENV = "true";
    }
    // optionalAttrs (profile.environment != null) profile.environment;

  # Nice + idle I/O so a multi-hour upload never competes with the media
  # services this host exists to run.
  hardening = {
    Nice = 10;
    IOSchedulingClass = "idle";
  };

  backupServices =
    mapAttrs' (name: profile:
      nameValuePair "rustic-${name}" {
        description = "rustic backup (profile ${name})";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        environment = profileEnv profile;
        onFailure = ["backup-notify@rustic-${name}.service"];
        serviceConfig =
          hardening
          // {
            Type = "oneshot";
            # No auto-init, unlike the retired module. `rustic init` against a
            # repo that merely *looks* empty — wrong bucket name, wrong
            # credentials scope — would silently create a second, fresh repo
            # and every backup after that would report success into the void.
            # Initialisation is a one-time deliberate act: `sudo rustic-<name> init`.
            ExecStart = "${cfg.package}/bin/rustic -P ${name} backup";
            EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
          };
      })
    cfg.profiles;

  pruneServices =
    mapAttrs' (name: profile:
      nameValuePair "rustic-${name}-prune" {
        description = "rustic forget + prune (profile ${name})";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        environment = profileEnv profile;
        onFailure = ["backup-notify@rustic-${name}-prune.service"];
        serviceConfig =
          hardening
          // {
            Type = "oneshot";
            # PRUNE OPTIONS are CLI-only: rustic 0.11.3 has no [prune] config
            # section and [forget] carries no keep-pack key, so --keep-pack
            # cannot move into the profile. Losing it silently means paying
            # OVH's early-deletion penalty (180-day minimum) on every prune.
            ExecStart = concatStringsSep " " (
              ["${cfg.package}/bin/rustic" "-P" name "forget"] ++ profile.pruneArgs
            );
            EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
          };
      })
    cfg.profiles;

  mkTimer = suffix: field:
    mapAttrs' (name: profile:
      nameValuePair "rustic-${name}${suffix}" {
        description = "Timer for rustic-${name}${suffix}";
        wantedBy = ["timers.target"];
        timerConfig = profile.${field};
      })
    (filterAttrs (_: p: p.${field} != null) cfg.profiles);

  profileScripts =
    mapAttrsToList (name: profile:
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
          (if profile.environment == null then {} else profile.environment))}
        exec ${cfg.package}/bin/rustic -P ${name} "$@"
      '')
    cfg.profiles;

  profileType = types.submodule {
    freeformType = types.attrs;
    options = {
      timerConfig = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "systemd timer for the backup unit. null means manual-only.";
        example = literalExpression ''{OnCalendar = "Sun *-*-* 04:30:00";}'';
      };
      pruneTimerConfig = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "systemd timer for the forget+prune unit. null means manual-only.";
        example = literalExpression ''{OnCalendar = "*-*-01 03:00:00";}'';
      };
      pruneArgs = mkOption {
        type = types.listOf types.str;
        default = ["--prune"];
        description = ''
          Arguments appended to `rustic -P <name> forget`. Retention comes from
          the profile's [forget] table; only CLI-only prune options belong here.
        '';
        example = literalExpression ''["--prune" "--keep-pack" "180d"]'';
      };
      environment = mkOption {
        type = types.nullOr (types.attrsOf types.str);
        default = null;
        description = "Extra environment for this profile's units. Never secrets.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "EnvironmentFile for this profile's units (S3 credentials etc.).";
        example = "/run/secrets/ovh-s3-env";
      };
      substituteEnv = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Pass RUSTIC_PROFILE_SUBSTITUTE_ENV=true, making rustic expand $VAR and
          ''${VAR} inside the profile. Required to keep credentials out of the
          Nix store. Note it applies to the whole profile — a literal `$` in any
          value (a glob, a path) would be substituted too.
        '';
      };
    };
  };
in {
  options.constellation.rustic = {
    enable = mkEnableOption "rustic backup profiles (cold-storage tier)";

    package = mkOption {
      type = types.package;
      default = pkgs-unstable.rustic;
      description = ''
        rustic package. Defaults to pkgs-unstable: stable is 0.11.2, and the
        cold-storage design was verified against 0.11.3.
      '';
    };

    logDir = mkOption {
      type = types.str;
      default = "/var/log/rustic";
      description = "Directory for per-profile rustic log files.";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/rustic";
      description = "Shared rustic cache directory.";
    };

    profiles = mkOption {
      type = types.attrsOf profileType;
      default = {};
      description = ''
        Attribute set of rustic profiles. Every attribute other than
        timerConfig, pruneTimerConfig, pruneArgs, environment, environmentFile
        and substituteEnv is written verbatim into /etc/rustic/<name>.toml.
      '';
    };
  };

  config = mkIf cfg.enable {
    constellation.backupNotify.enable = mkDefault true;

    environment.systemPackages = [cfg.package] ++ profileScripts;

    environment.etc =
      mapAttrs' (name: profile:
        nameValuePair "rustic/${name}.toml" {source = profileToml name profile;})
      cfg.profiles;

    systemd.services = backupServices // pruneServices;
    systemd.timers = (mkTimer "" "timerConfig") // (mkTimer "-prune" "pruneTimerConfig");

    systemd.tmpfiles.rules = [
      "d ${cfg.logDir} 0750 root root -"
      "d ${cfg.cacheDir} 0750 root root -"
    ];
  };
}
```

- [ ] **Step 4: Format and build**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just fmt
nix develop -c nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```

Expected: build succeeds. **Read the last line for the error count.**

- [ ] **Step 5: Re-run the check**

Run: `bash /tmp/rustic-plan-checks/check-rustic-module.sh`
Expected: prints the option description and `PASS`.

- [ ] **Step 6: Confirm nothing is emitted while disabled**

```bash
cd /home/arosenfeld/Code/nixos
nix eval .#nixosConfigurations.galactica.config.systemd.services --apply \
  's: builtins.filter (n: builtins.match "rustic.*" n != null) (builtins.attrNames s)'
```

Expected: `[ ]` — the module is inert until a host enables it.

- [ ] **Step 7: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add modules/constellation/rustic.nix
git commit -m "feat(modules): add constellation.rustic for the cold-storage tier"
```

---

## Task 3: OVH buckets, S3 credentials, sops secrets

Driven entirely from `ovhcloud-cli` — no console clicking. **This task creates billable resources.** Get operator confirmation before Step 2.

**Files:**
- Modify: `secrets/sops/galactica.yaml`

**Interfaces:**
- Produces: sops keys `rustic-ovh-password` (a repo password) and `ovh-s3-env` (an `EnvironmentFile` defining `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`). Task 4 references both by name.
- Produces: bucket names `galactica-backup-cold` and `galactica-backup-hot` in region `EU-WEST-PAR`. Task 4 hardcodes these.

### About the CLI

`nix run nixpkgs#ovhcloud-cli -- …` is already authenticated on this workstation (verified during planning). Everything below uses it. Useful facts established while writing this plan:

- **Exactly one project exists:** `648a07cf50554fe69f452efc9ab6ce6d` ("Default Project"). Confirm with Step 1 rather than trusting this id.
- **`EU-WEST-PAR` is a valid region** (uppercase in CLI positionals; `eu-west-par` lowercase in the S3 endpoint and rustic's `region` option), with AZs `-a`/`-b`/`-c` — the "Paris 3-AZ" of the design.
- **At planning time the project had zero containers and zero users.** If `list` shows any, stop and reconcile before creating more.
- `cloud storage object create` has **no storage-class flag**, which is correct: Cold Archive v2 is an *object*-level class that rustic sets per write via `default_storage_class`. There is nothing to configure on the bucket.
- `--init-file` / `--editor` need a TTY and will fail under an agent (`could not open a new TTY`). Use plain flags only.
- The CLI prints a spurious `A new version of ovhcloud-cli is available: v0.12.0 (current: 0.12.0)` line to stderr. Ignore it; do not run `ovhcloud upgrade`.

Define this shell alias for the whole task:

```bash
ovh() { nix run nixpkgs#ovhcloud-cli -- "$@"; }
```

- [ ] **Step 1: Confirm the project and the starting state**

```bash
ovh() { nix run nixpkgs#ovhcloud-cli -- "$@"; }
P=$(ovh cloud project list -o json | jq -r '.[0].project_id')
echo "project = $P"
ovh cloud storage object list --cloud-project "$P" -o json
ovh cloud user list --cloud-project "$P" -o json
```

Expected: one project id; `null` for both lists. If either list is non-empty, stop — this plan assumes a clean project and would otherwise be creating duplicates.

- [ ] **Step 2: Get operator confirmation, then create the two buckets**

State plainly: this creates two S3 containers in `EU-WEST-PAR` and starts billing at $0.002/GB/month for whatever lands in the cold one, with a **180-day minimum storage duration** per object. Wait for a yes.

```bash
ovh cloud storage object create EU-WEST-PAR --name galactica-backup-cold --cloud-project "$P" -o json
ovh cloud storage object create EU-WEST-PAR --name galactica-backup-hot  --cloud-project "$P" -o json
ovh cloud storage object list --cloud-project "$P" -o json
```

Expected: both containers listed, region `EU-WEST-PAR`.

Do **not** add a lifecycle rule transitioning objects into Cold Archive (`cloud storage object lifecycle`). OVH does not support transitions *into* the class; rustic writes objects directly in it.

- [ ] **Step 3: Create the S3 user**

```bash
U=$(ovh cloud user create --cloud-project "$P" \
      --description "rustic cold archive (galactica)" \
      --roles objectstore_operator -o json | jq -r '.id')
echo "user = $U"
```

Expected: a numeric user id.

If the API rejects `objectstore_operator`, it returns the list of valid role names in the error body — use the one granting object-storage access, and record which it was. Do **not** fall back to `administrator`; this credential lives on galactica's disk and only needs object storage.

- [ ] **Step 4: Grant the user read/write on both buckets**

The project role alone may already suffice, but grant explicitly so the credential's scope is visible rather than inferred:

```bash
ovh cloud storage object add-user galactica-backup-cold "$U" readWrite --cloud-project "$P"
ovh cloud storage object add-user galactica-backup-hot  "$U" readWrite --cloud-project "$P"
```

Expected: success on both. If a role of `readWrite` is rejected, the accepted set is `admin`, `deny`, `readOnly`, `readWrite`.

- [ ] **Step 5: Mint S3 credentials**

```bash
ovh cloud storage object credentials create "$U" --cloud-project "$P" -o json
```

Expected: JSON containing an access key and a secret key. **The secret is shown once** — capture it now. Keep it out of the shell history file; the next step writes it straight into sops.

- [ ] **Step 6: Confirm the endpoint hostname**

```bash
ovh cloud storage object get galactica-backup-cold --cloud-project "$P" -o json
```

Look for the container's S3 endpoint / virtual host in the response. It should correspond to `https://s3.eu-west-par.io.cloud.ovh.net`.

That host was already verified live during planning — a signed request to it returned a well-formed S3 `SignatureDoesNotMatch` with an `x-amz-request-id`. If the CLI reports a different hostname, stop and update `endpoint` in Task 4 before proceeding.

- [ ] **Step 7: Generate and store the repo password**

```bash
cd /home/arosenfeld/Code/nixos
pw=$(openssl rand -base64 48 | tr -d '\n=')
nix develop -c sops set secrets/sops/galactica.yaml '["rustic-ovh-password"]' "\"$pw\""
```

This is deliberately **not** the shared `restic-password` from `common.yaml`. That secret is readable by basestar, pegasus and raider; scoping the archive to a galactica-only key means compromising raider does not hand over the durable copy. Recovery is unchanged — both live in git and decrypt with the age key.

- [ ] **Step 8: Store the S3 credentials**

Substitute the access key and secret key captured in Step 5:

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c sops set secrets/sops/galactica.yaml '["ovh-s3-env"]' \
  '"AWS_ACCESS_KEY_ID=<access key from Step 5>\nAWS_SECRET_ACCESS_KEY=<secret key from Step 5>\n"'
```

The `AWS_*` names are chosen so one secret feeds both rustic's profile substitution and `awscli2` in the restore scripts.

- [ ] **Step 9: Verify both decrypt**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c sops --decrypt secrets/sops/galactica.yaml | grep -A3 -E '^(rustic-ovh-password|ovh-s3-env):'
```

Expected: the password on one line, and `ovh-s3-env` as a two-line block scalar with both `AWS_*` assignments.

- [ ] **Step 10: Sanity-check the credentials against OVH**

Read the credentials back out of sops rather than pasting them a second time — this also proves the stored value is well-formed as an `EnvironmentFile`:

```bash
cd /home/arosenfeld/Code/nixos
( set -a
  eval "$(nix develop -c sops --decrypt --extract '["ovh-s3-env"]' secrets/sops/galactica.yaml)"
  set +a
  nix shell nixpkgs#awscli2 -c aws s3api list-objects-v2 \
    --endpoint-url https://s3.eu-west-par.io.cloud.ovh.net \
    --region eu-west-par --bucket galactica-backup-cold --max-items 1 )
```

Expected: empty JSON (`{}` or a response with no `Contents`), exit 0. A `SignatureDoesNotMatch` means the keys are wrong; `NoSuchBucket` means the bucket name or region is wrong. Run it again against `galactica-backup-hot`.

- [ ] **Step 11: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add secrets/sops/galactica.yaml
git commit -m "feat(secrets): add rustic-ovh-password and ovh-s3-env for galactica"
```

---

## Task 4: galactica's `ovh` profile, timers disabled

All OVH-specific knowledge lands here. The timers stay `null`, so deploying this changes nothing about what runs — it only makes `/etc/rustic/ovh.toml` and the two units exist.

**Files:**
- Create: `hosts/galactica/backup/rustic-ovh.nix`
- Modify: `hosts/galactica/backup/default.nix`
- Test: `rustic show-config` against the rendered TOML

**Interfaces:**
- Consumes: `constellation.rustic.profiles.<name>` (Task 2); sops keys from Task 3; bucket names and endpoint from Task 3.
- Produces: `/etc/rustic/ovh.toml`; units `rustic-ovh.service` and `rustic-ovh-prune.service`; the wrapper `rustic-ovh` on `PATH`. Tasks 5-9 drive all three.
- Produces: two warm-up scripts taking one argument that may contain space-separated pack ids.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/rustic-plan-checks/check-ovh-profile.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/arosenfeld/Code/nixos

toml=$(nix eval --raw .#nixosConfigurations.galactica.config.environment.etc."rustic/ovh.toml".source)
echo "profile = $toml"

# rustic must be able to parse it. show-config exits 0 only on a valid profile.
#
# The rendered profile points global.log-file at /var/log/rustic/ovh.log, which
# a non-root user on the workstation cannot open — rustic then dies with
# "config error: Permission denied" before it ever validates anything. Redirect
# the log path for the check; everything else is byte-identical.
work=$(mktemp -d)
sed 's#^log-file = .*#log-file = "'"$work"'/ovh.log"#' "$toml" > "$work/ovh.toml"
out=$(cd "$work" && nix shell nixpkgs/nixos-unstable#rustic -c rustic -P ./ovh show-config)

grep -q 'default_storage_class = "DEEP_ARCHIVE"' <<<"$out" || { echo "FAIL: cold class missing"; exit 1; }
grep -q 'repo-hot = "opendal:s3"'                 <<<"$out" || { echo "FAIL: repo-hot missing"; exit 1; }
[ "$(grep -c '^\[\[backup.snapshots\]\]' <<<"$out")" -eq 2 ] || { echo "FAIL: expected 2 snapshot definitions"; exit 1; }
grep -q 'label = "system"' <<<"$out" || { echo "FAIL: system label missing"; exit 1; }
grep -q 'label = "user"'   <<<"$out" || { echo "FAIL: user label missing"; exit 1; }

# Exclude parity, structurally: every restic exclude must appear as a !glob.
for p in /home /mnt /dev /proc /sys /run /tmp /nix /var/cache /var/lib/docker \
         /var/lib/containers /var/lib/lxcfs /var/lib/loki /var/lib/prometheus2 \
         /mnt/storage/backups /mnt/storage/media /mnt/storage/homes \
         /mnt/storage/legacy '/home/*/.cache' '/home/*/torrents'; do
  grep -qF "\"!$p\"" <<<"$out" || { echo "FAIL: missing glob !$p"; exit 1; }
done

rm -rf "$work"
echo "PASS"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash /tmp/rustic-plan-checks/check-ovh-profile.sh`
Expected: FAIL — `error: attribute 'rustic/ovh.toml' missing`

- [ ] **Step 3: Create the host profile**

Create `hosts/galactica/backup/rustic-ovh.nix`:

```nix
# galactica's cold backup tier: OVHcloud Cold Archive v2 via rustic.
#
# Replaces the Hetzner Storage Box (~€10.90/mo) with ~€4/mo of tape. Cold
# Archive v2 is an object-level storage class inside an ordinary S3 bucket
# (v1 was bucket-granular and sealed the whole bucket against reads and
# writes, which no incremental repo can survive).
#
# Two buckets, both in eu-west-par — the only region that offers the class:
#   galactica-backup-cold   data packs, written directly as DEEP_ARCHIVE
#   galactica-backup-hot    keys, snapshots, index, tree packs (Standard)
#
# Everything rustic reads for `snapshots`, `ls`, `find` and `check` lives in
# the hot repo, so only real file data ever touches tape.
#
# Cost trap to keep in mind before touching anything here: Cold Archive has a
# 180-day minimum storage duration. Deleting an object early still bills
# (180 - days used) x price. That is why the prune unit passes
# `--keep-pack 180d` — see constellation.rustic's pruneArgs comment.
{
  config,
  lib,
  pkgs,
  ...
}: let
  endpoint = "https://s3.eu-west-par.io.cloud.ovh.net";
  region = "eu-west-par";
  coldBucket = "galactica-backup-cold";
  hotBucket = "galactica-backup-hot";

  # Kept 1:1 with backrest-client.nix's systemExcludes / userExcludes: these
  # two rustic snapshots replace the hetzner-system and hetzner plans exactly.
  # restic's `--exclude <path>` and rustic's `globs = ["!<path>"]` were
  # verified to produce identical file and byte totals on a control tree,
  # including the `/home/*/…` patterns.
  systemExcludes = [
    "/home"
    "/mnt"
    "/dev"
    "/proc"
    "/sys"
    "/run"
    "/tmp"
    "/nix"
    "/var/cache"
    "/var/lib/docker"
    "/var/lib/containers"
    "/var/lib/lxcfs"
    "/var/lib/loki"
    "/var/lib/prometheus2"
  ];

  userExcludes = [
    "/mnt/storage/backups"
    "/mnt/storage/media"
    "/mnt/storage/homes"
    "/mnt/storage/legacy"
    "/home/*/.cache"
    "/home/*/torrents"
  ];

  toGlobs = map (p: "!" + p);

  # rustic substitutes %id with ONE argument holding space-separated pack ids
  # when warm-up-batch > 1 (verified against 0.11.3: a probe script saw
  # ARGC=1 while `echo %id` printed 11 ids on a line). Iterating over the
  # unquoted argument is therefore correct at any batch size, including 1.
  warmUp = pkgs.writeShellScript "rustic-ovh-warm-up" ''
    set -euo pipefail
    export AWS_DEFAULT_REGION=${region}
    export AWS_EC2_METADATA_DISABLED=true
    for id in $1; do
      key="data/''${id:0:2}/$id"
      if ! err=$(${pkgs.awscli2}/bin/aws s3api restore-object \
            --endpoint-url ${endpoint} \
            --bucket ${coldBucket} \
            --key "$key" \
            --restore-request '{"Days":7}' 2>&1); then
        case "$err" in
          *RestoreAlreadyInProgress*) ;;  # another pack in the same run got there first
          *) echo "restore-object failed for $key: $err" >&2; exit 1 ;;
        esac
      fi
    done
  '';

  # Poll rather than guess. `warm-up-wait = "48h"` would make every restore
  # take 48 hours; this makes it take as long as OVH actually takes.
  warmUpWait = pkgs.writeShellScript "rustic-ovh-warm-up-wait" ''
    set -euo pipefail
    export AWS_DEFAULT_REGION=${region}
    export AWS_EC2_METADATA_DISABLED=true
    deadline=$(( $(date +%s) + 172800 ))   # 48 h, OVH's documented ceiling
    for id in $1; do
      key="data/''${id:0:2}/$id"
      while :; do
        json=$(${pkgs.awscli2}/bin/aws s3api head-object \
                 --endpoint-url ${endpoint} --bucket ${coldBucket} --key "$key")
        class=$(${pkgs.jq}/bin/jq -r '.StorageClass // "STANDARD"' <<<"$json")
        restore=$(${pkgs.jq}/bin/jq -r '.Restore // ""' <<<"$json")
        # Not on tape: nothing to wait for. Covers hot-repo packs and any
        # object that predates the DEEP_ARCHIVE default.
        [ "$class" = "DEEP_ARCHIVE" ] || break
        case "$restore" in
          *'ongoing-request="false"'*) break ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "warm-up timed out after 48h waiting for $key" >&2
          exit 1
        fi
        sleep 60
      done
    done
  '';
in {
  # Deliberately NOT the shared restic-password from common.yaml, which
  # basestar, pegasus and raider can all decrypt. A galactica-only key means
  # compromising raider does not also hand over the durable archive.
  sops.secrets."rustic-ovh-password" = {
    mode = "0400";
  };

  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. Consumed twice: rustic expands
  # ${AWS_*} inside the profile (substituteEnv), and awscli2 reads the same
  # names in the warm-up scripts.
  sops.secrets."ovh-s3-env" = {
    mode = "0400";
  };

  constellation.rustic = {
    enable = true;

    profiles.ovh = {
      # Both timers stay null until the seed and the restore drill have
      # passed. Turning them on is a one-line change; see the plan's Task 9.
      timerConfig = null;
      pruneTimerConfig = null;

      # --keep-pack is CLI-only in rustic 0.11.3: there is no [prune] config
      # section and [forget] carries no keep-pack key. It keeps exclusively
      # dead packs on tape for six months so no prune ever trips OVH's
      # 180-day early-deletion penalty.
      pruneArgs = ["--prune" "--keep-pack" "180d"];

      substituteEnv = true;
      environmentFile = config.sops.secrets."ovh-s3-env".path;

      repository = {
        repository = "opendal:s3"; # cold
        repo-hot = "opendal:s3"; # hot
        password-file = config.sops.secrets."rustic-ovh-password".path;
        warm-up-command = "${warmUp} %id";
        warm-up-wait-command = "${warmUpWait} %id";
        warm-up-batch = 1;

        options-cold = {
          bucket = coldBucket;
          endpoint = endpoint;
          region = region;
          # The whole design hangs on this string. opendal ignores unknown
          # option keys silently, so a typo here would write terabytes at the
          # Standard rate with no error anywhere — head-object a data pack
          # after the first real backup and confirm the class.
          default_storage_class = "DEEP_ARCHIVE";
          access_key_id = "\${AWS_ACCESS_KEY_ID}";
          secret_access_key = "\${AWS_SECRET_ACCESS_KEY}";
        };

        options-hot = {
          bucket = hotBucket;
          endpoint = endpoint;
          region = region;
          access_key_id = "\${AWS_ACCESS_KEY_ID}";
          secret_access_key = "\${AWS_SECRET_ACCESS_KEY}";
        };
      };

      # Replaces the hetzner-system and hetzner Backrest plans respectively.
      # `label` is part of rustic's default group-by (host,label,paths), so
      # the two sets retain independently.
      backup.snapshots = [
        {
          sources = ["/"];
          globs = toGlobs systemExcludes;
          label = "system";
        }
        {
          sources = ["/home" "/mnt/storage"];
          globs = toGlobs userExcludes;
          label = "user";
        }
      ];

      # Matches remoteRetention in backrest-client.nix. `prune` is left unset
      # (defaults false) — the backup unit never forgets, and the prune unit
      # passes --prune on the command line.
      forget = {
        keep-daily = 7;
        keep-weekly = 4;
        keep-monthly = 6;
      };
    };
  };
}
```

- [ ] **Step 4: Import it**

Replace `hosts/galactica/backup/default.nix` with:

```nix
{
  imports = [
    ./backup-server.nix
    ./backrest-client.nix
    ./rustic-ovh.nix
  ];
}
```

- [ ] **Step 5: Format and build**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just fmt
nix develop -c nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```

Expected: build succeeds. **Read the last line for the error count.**

- [ ] **Step 6: Re-run the profile check**

Run: `bash /tmp/rustic-plan-checks/check-ovh-profile.sh`
Expected: `PASS`. This proves rustic itself parses the generated TOML and that all 20 excludes survived translation.

- [ ] **Step 7: Confirm no credentials leaked into the store**

```bash
cd /home/arosenfeld/Code/nixos
toml=$(nix eval --raw .#nixosConfigurations.galactica.config.environment.etc."rustic/ovh.toml".source)
grep -E 'access_key_id|secret_access_key' "$toml"
```

Expected: exactly `access_key_id = "${AWS_ACCESS_KEY_ID}"` and `secret_access_key = "${AWS_SECRET_ACCESS_KEY}"` — literal, unexpanded.

- [ ] **Step 8: Confirm the timers are absent**

```bash
cd /home/arosenfeld/Code/nixos
nix eval .#nixosConfigurations.galactica.config.systemd.timers --apply \
  's: builtins.filter (n: builtins.match "rustic.*" n != null) (builtins.attrNames s)'
```

Expected: `[ ]`.

- [ ] **Step 9: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add hosts/galactica/backup/rustic-ovh.nix hosts/galactica/backup/default.nix
git commit -m "feat(galactica): add the OVH Cold Archive rustic profile (timers off)"
```

---

## Task 5: Deploy, initialise, and prove the cold storage class

The single most important gate in the plan and the cheapest. A silent `default_storage_class` failure costs ~$16/month instead of ~$4 and produces no error. A few megabytes are written here; the 180-day minimum on them is negligible.

**Files:** none — this is deploy + verification.

**Interfaces:**
- Consumes: everything from Tasks 3 and 4.
- Produces: an initialised hot/cold repo with one throwaway snapshot, and a confirmed `StorageClass` on a real data pack.

- [ ] **Step 1: Deploy**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy galactica
```

Expected: success. **Read the last line for the error count.**

- [ ] **Step 2: Confirm the profile and units landed**

```bash
ssh galactica.bat-boa.ts.net 'sudo ls -l /etc/rustic/ && systemctl list-unit-files "rustic-*"'
```

Expected: `ovh.toml` present; `rustic-ovh.service` and `rustic-ovh-prune.service` listed as `static`; **no** `rustic-ovh.timer`.

- [ ] **Step 3: Initialise the repository**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh init'
```

Expected: `[INFO] repository … successfully initialized.` If this fails with `SignatureDoesNotMatch`, the credentials in `ovh-s3-env` are wrong; with `NoSuchBucket`, the bucket names or region are wrong.

- [ ] **Step 4: Write one tiny snapshot**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh backup --label smoke /etc/os-release /etc/machine-id'
```

Expected: a snapshot id, a handful of files, kilobytes.

These paths match neither configured `[[backup.snapshots]]` entry, so rustic creates an ad-hoc snapshot carrying the CLI `--label` — verified against 0.11.3, and it is what makes Step 8's `--filter-label smoke` able to find it again. (Contrast Task 7, where the sources *do* match an entry and `--label` must be omitted.)

- [ ] **Step 5: Prove the data packs are on tape**

```bash
ssh galactica.bat-boa.ts.net 'sudo bash -c "
  set -a; . /run/secrets/ovh-s3-env; set +a
  export AWS_DEFAULT_REGION=eu-west-par AWS_EC2_METADATA_DISABLED=true
  aws s3api list-objects-v2 --endpoint-url https://s3.eu-west-par.io.cloud.ovh.net \
    --bucket galactica-backup-cold --prefix data/ \
    --query \"Contents[].{Key:Key,Class:StorageClass}\" --output table
"'
```

Expected: at least one row under `data/`, every `Class` reading **`DEEP_ARCHIVE`**.

**If any row reads `STANDARD`, STOP.** Do not proceed to the seed. The `default_storage_class` option is not being honoured — re-check the exact spelling in `options-cold`, confirm the account has Cold Archive v2 enabled, and re-run from Step 3 after deleting the test objects.

- [ ] **Step 6: Prove the hot repo carries the metadata**

```bash
ssh galactica.bat-boa.ts.net 'sudo bash -c "
  set -a; . /run/secrets/ovh-s3-env; set +a
  export AWS_DEFAULT_REGION=eu-west-par AWS_EC2_METADATA_DISABLED=true
  for b in galactica-backup-hot galactica-backup-cold; do
    echo \"== \$b\"
    aws s3api list-objects-v2 --endpoint-url https://s3.eu-west-par.io.cloud.ovh.net \
      --bucket \$b --query \"Contents[].Key\" --output text | tr \"\\t\" \"\\n\" | cut -d/ -f1 | sort | uniq -c
  done
"'
```

Expected: the hot bucket holds `config`, `keys`, `snapshots`, `index` and tree packs; the cold bucket holds the data packs. Record what each bucket actually contains — this is the empirical answer to "what is on tape", and it determines whether metadata operations ever need a warm-up.

- [ ] **Step 7: Prove metadata reads need no warm-up**

```bash
ssh galactica.bat-boa.ts.net 'time sudo rustic-ovh snapshots'
```

Expected: the smoke snapshot listed, in seconds, with no warm-up log lines. This is the property that makes `rustic check` and `rustic ls` usable at all.

- [ ] **Step 8: Remove the smoke snapshot's metadata**

```bash
# Get the id first, then forget it explicitly.
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh snapshots'
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh forget <snapshot-id>'
```

**Corrected during execution — do not use `--filter-label smoke --keep-none`.** That was this plan's original instruction and it silently does nothing. rustic merges the profile's `[forget]` policy *additively* with CLI retention flags rather than letting `--keep-none` override them, so the sole snapshot in its group still satisfies "most recent daily/weekly/monthly" and is kept. Observed on 0.11.3 against the real repo.

Forgetting by explicit id bypasses the retention policy entirely — rustic reports `Action: remove, Reason: if argument`. That is the reliable form.

(For reference, the filter flag is `--filter-label`, singular, while the config key in `[forget]` is `filter-labels`, plural.)

Do **not** run `--prune`. The few kilobytes of packs stay on tape until a prune eventually removes them past the 180-day floor; deleting them now would incur the early-deletion charge for no benefit.

Expected: the smoke snapshot removed from `rustic-ovh snapshots`.

- [ ] **Step 9: Record the outcome**

No commit — append the observed bucket layout and storage classes to the plan's "Execution log" section at the bottom of this file, then:

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/plans/2026-07-27-ovh-cold-archive-rustic.md
git commit -m "docs(galactica): record OVH cold-class smoke test results"
```

---

## Task 6: Exclude parity gate

The spec's highest-risk item. Permissive in one direction pushes terabytes of Plex media to tape under a 180-day minimum that cannot be cheaply undone; permissive in the other silently drops something irreplaceable. Structural parity was already proven in Task 4 Step 6; this proves *behavioural* parity against the real filesystem.

**Files:** none — verification only.

**Interfaces:**
- Consumes: the deployed `ovh` profile, the existing hetzner repo (still live).
- Produces: two file/byte totals per snapshot definition and an explained delta. Gates Task 7.

- [ ] **Step 1: Get restic's reference numbers**

```bash
ssh galactica.bat-boa.ts.net 'sudo bash -c "
  set -a; . /run/secrets/hetzner-webdav-env; set +a
  export RESTIC_PASSWORD_FILE=/run/secrets/restic-password
  export RESTIC_REPOSITORY=rclone:hetzner:backups/restic
  restic snapshots --json | jq -r \".[] | [.short_id, .time, (.paths|join(\\\",\\\"))] | @tsv\" | tail -8
"'
```

Note the most recent snapshot id whose paths are `/` (the `hetzner-system` plan) and the most recent whose paths are `/home,/mnt/storage` (the `hetzner` plan).

```bash
ssh galactica.bat-boa.ts.net 'sudo bash -c "
  set -a; . /run/secrets/hetzner-webdav-env; set +a
  export RESTIC_PASSWORD_FILE=/run/secrets/restic-password
  export RESTIC_REPOSITORY=rclone:hetzner:backups/restic
  for id in <SYSTEM_ID> <USER_ID>; do
    echo \"== \$id\"
    restic stats \$id --mode restore-size --json
  done
"'
```

Record `total_file_count` and `total_size` for each. These are the reference figures.

- [ ] **Step 2: Run the rustic dry-run**

`--dry-run` writes nothing; ingress and API calls on OVH are free. It does read and chunk every included file, so expect **1-3 hours** for the user set on spinning disks. Run it detached.

```bash
ssh galactica.bat-boa.ts.net 'sudo systemd-run --unit=rustic-parity-gate --collect \
  --property=Nice=19 --property=IOSchedulingClass=idle \
  /run/current-system/sw/bin/rustic-ovh backup --dry-run --json'
```

Follow it with:

```bash
ssh galactica.bat-boa.ts.net 'journalctl -u rustic-parity-gate -f'
```

- [ ] **Step 3: Extract rustic's numbers**

```bash
ssh galactica.bat-boa.ts.net \
  'journalctl -u rustic-parity-gate -o cat | jq -c "select(.summary) | {label: .label, files: .summary.total_files_processed, bytes: .summary.total_bytes_processed}"'
```

Expected: two objects, one per label.

- [ ] **Step 4: Diff and decide**

Compare per snapshot definition:

| | restic `total_file_count` / `total_size` | rustic `total_files_processed` / `total_bytes_processed` |
|---|---|---|
| system (`/`) | | |
| user (`/home`, `/mnt/storage`) | | |

**The gate:** proceed only when each pair agrees within an explained delta. Deltas that are legitimate:

- **Small and positive on rustic's side** — files created since restic's last snapshot ran (up to a week old). Expect a few thousand files on the system set.
- **`/var/log`, `/var/lib/*` churn** — both tools include these; sizes drift.

Deltas that are **not** acceptable and must be diagnosed before continuing:

- **rustic larger by hundreds of GB or more** — an exclude did not match. Almost certainly `/mnt/storage/media`. Nothing gets seeded until this is understood.
- **rustic smaller by more than a rounding margin** — an exclude is over-matching and something is silently not being backed up.

- [ ] **Step 5: Diagnose a failing gate (only if Step 4 fails)**

rustic emits no per-file lines even at `--log-level debug`, so narrow it by bisecting the source list. Run the dry-run against one subtree at a time with the full glob list applied, and compare against `restic ls <snapshot> <subtree> | wc -l`:

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh backup --dry-run --json \
  --glob "!/mnt/storage/backups" --glob "!/mnt/storage/media" \
  --glob "!/mnt/storage/homes" --glob "!/mnt/storage/legacy" \
  --glob "!/home/*/.cache" --glob "!/home/*/torrents" \
  /mnt/storage | jq -c ".summary"'
```

Do **not** point a dry-run directly at an excluded directory as a shortcut — when a source path is itself an excluded path, rustic's exclude does not apply (verified) and you will get a misleading result.

- [ ] **Step 6: Record the outcome**

Append the four numbers and the explanation of the delta to the "Execution log" section, then commit:

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/plans/2026-07-27-ovh-cold-archive-rustic.md
git commit -m "docs(galactica): record the rustic/restic exclude parity gate result"
```

---

## Task 7: Seed the archive

~1966 GB across the two snapshot definitions. At the measured 157.94 Mbit/s uplink this is ~29 h at line rate; plan for 2-4 days.

**Files:** none — operations only.

**Interfaces:**
- Consumes: a passed parity gate (Task 6) and a confirmed `DEEP_ARCHIVE` class (Task 5).
- Produces: two real snapshots in the OVH repo. Gates Task 8.

- [ ] **Step 1: Seed the system snapshot first**

171 GiB, ~2.5 h. Doing it first means any surprise surfaces on the small set.

```bash
ssh galactica.bat-boa.ts.net 'sudo systemd-run --unit=rustic-seed-system --collect \
  --property=Nice=19 --property=IOSchedulingClass=idle \
  /run/current-system/sw/bin/rustic-ovh backup /'
```

Passing `/` on the command line selects the matching `[[backup.snapshots]]` entry, and **the profile's globs and label still apply** — verified against 0.11.3 with both entries configured. Do not add `--label`; the label comes from the matched entry, and hand-setting it would let a mismatched invocation look correct.

Watch: `ssh galactica.bat-boa.ts.net 'journalctl -u rustic-seed-system -f'`

- [ ] **Step 2: Verify the system snapshot**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh snapshots'
```

Expected: one snapshot labelled **`system`** — if the label is empty or reads `user`, the CLI source did not match the intended entry and the wrong glob set was applied. Stop and investigate before seeding the large set. Size should be in the same range as restic's reference figure from Task 6.

- [ ] **Step 3: Seed the user snapshot**

1.7 TiB. This is the multi-day one.

```bash
ssh galactica.bat-boa.ts.net 'sudo systemd-run --unit=rustic-seed-user --collect \
  --property=Nice=19 --property=IOSchedulingClass=idle \
  /run/current-system/sw/bin/rustic-ovh backup /home /mnt/storage'
```

**If the household link suffers:** rustic has no rate limit, and the router's CAKE shaper is configured at 2250 Mbit/s against a ~158 Mbit/s real uplink, so it never engages. Two levers, in order of preference:

1. **Pause and resume.** `sudo systemctl stop rustic-seed-user`, restart the same command later. rustic writes index files as it goes, so a restart re-uploads only what was in flight — not the whole set.
2. **Cap galactica's egress temporarily.** Discover the interface first, and remember this caps *all* of galactica's outbound traffic including remote Plex:

```bash
ssh galactica.bat-boa.ts.net 'ip route get 1.1.1.1 | head -1'          # find <iface>
ssh galactica.bat-boa.ts.net 'sudo tc qdisc add dev <iface> root tbf rate 100mbit burst 32kbit latency 400ms'
# … and afterwards, without fail:
ssh galactica.bat-boa.ts.net 'sudo tc qdisc del dev <iface> root'
```

- [ ] **Step 4: Verify both snapshots exist**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh snapshots'
```

Expected: two snapshots, labels `system` and `user`.

- [ ] **Step 5: Confirm the seeded packs are on tape**

Re-run Task 5 Step 5. Expected: many `data/` objects, **all** `DEEP_ARCHIVE`.

- [ ] **Step 6: Record actual sizes and durations**

Append wall-clock durations, transferred bytes, and the resulting per-bucket object counts to the "Execution log", then commit.

---

## Task 8: Integrity check and restore drill

**Files:** none — operations only.

**Interfaces:**
- Consumes: a seeded repo (Task 7).
- Produces: proof that both warm-up scripts work end to end, plus real restore timings. Gates Task 9 and, transitively, Task 11.

- [ ] **Step 1: Resolve the retrieval-fee question first**

The spec flagged this as unresolved: OVH documents that a restored copy is billed at the Standard rate for the requested `Days` and that egress is free, but whether an additional per-GB retrieval charge applies could not be confirmed. Check the OVH console's pricing page for `eu-west-par` Cold Archive before issuing any restore.

If a per-GB retrieval fee does exist, the drill in Step 4 stays worth running (a handful of files), but note the figure in the "Execution log" — it changes the disaster-recovery cost estimate, not the architecture.

- [ ] **Step 2: Check the repository — metadata only**

```bash
ssh galactica.bat-boa.ts.net 'sudo systemd-run --wait --collect --unit=rustic-check \
  /run/current-system/sw/bin/rustic-ovh check'
ssh galactica.bat-boa.ts.net 'journalctl -u rustic-check -o cat | tail -20'
```

Expected: no errors. **Never pass `--read-data`** — it would pull every data pack off tape and bill for the lot.

- [ ] **Step 3: Pick target files**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh ls latest --long | head -40'
```

Choose two or three small files from the `user` snapshot whose content you can verify against the live filesystem.

- [ ] **Step 4: Run the restore drill**

```bash
ssh galactica.bat-boa.ts.net 'sudo systemd-run --unit=rustic-drill --collect \
  /run/current-system/sw/bin/rustic-ovh restore "latest:<path/to/file>" /tmp/rustic-drill'
ssh galactica.bat-boa.ts.net 'journalctl -u rustic-drill -f'
```

Expected in the journal, in order:
1. `[INFO] using warm-up command /nix/store/…-rustic-ovh-warm-up '%id' with batch size 1`
2. `warming up Pack(s)…`
3. a wait while `rustic-ovh-warm-up-wait` polls (this is where OVH's real latency shows up — minutes to hours, up to 48 h)
4. the restore itself

- [ ] **Step 5: Verify the restored bytes**

```bash
ssh galactica.bat-boa.ts.net 'sudo diff -r /tmp/rustic-drill<path> <original path> && echo IDENTICAL'
```

Expected: `IDENTICAL`.

- [ ] **Step 6: Clean up**

```bash
ssh galactica.bat-boa.ts.net 'sudo rm -rf /tmp/rustic-drill'
```

- [ ] **Step 7: Record real timings**

Append to the "Execution log": time from `restore-object` to `ongoing-request="false"`, total restore wall-clock, and the retrieval-fee answer from Step 1. These are the numbers a future disaster-recovery decision is made on. Commit.

---

## Task 9: Enable the timers and prove the failure path

**Files:**
- Modify: `hosts/galactica/backup/rustic-ovh.nix`

**Interfaces:**
- Consumes: a passed restore drill (Task 8).
- Produces: `rustic-ovh.timer` (Sun 04:30) and `rustic-ovh-prune.timer` (monthly). Gates Task 10.

- [ ] **Step 1: Set the two timers**

In `hosts/galactica/backup/rustic-ovh.nix`, replace the two `null` timer lines and their comment with:

```nix
      # Sunday 04:30, taking over the slot the hetzner-system plan used to
      # hold. One unit covers both snapshot definitions, so the old 05:30
      # hetzner slot is simply gone.
      timerConfig = {
        OnCalendar = "Sun *-*-* 04:30:00";
        Persistent = true;
      };

      # Monthly, not weekly. Pruning a cold repo is a slow, mostly pointless
      # operation — --repack-cacheable-only defaults to true on a hot/cold
      # repository, so prune never repacks cold data packs and simply waits
      # until every blob in a pack is unused.
      pruneTimerConfig = {
        OnCalendar = "*-*-01 03:00:00";
        Persistent = true;
      };
```

- [ ] **Step 2: Format, build, deploy**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just fmt
nix develop -c nix build .#nixosConfigurations.galactica.config.system.build.toplevel
nix develop -c just deploy galactica
```

Expected: build and deploy succeed. **Read the last line for the error count.**

- [ ] **Step 3: Confirm the timers are armed**

```bash
ssh galactica.bat-boa.ts.net 'systemctl list-timers "rustic-*" --all'
```

Expected: `rustic-ovh.timer` next Sunday 04:30, `rustic-ovh-prune.timer` on the 1st at 03:00.

- [ ] **Step 4a: Confirm the real units carry `OnFailure`**

```bash
ssh galactica.bat-boa.ts.net \
  'systemctl show rustic-ovh.service -p OnFailure; systemctl show rustic-ovh-prune.service -p OnFailure'
```

Expected: `OnFailure=backup-notify@rustic-ovh.service` and `OnFailure=backup-notify@rustic-ovh-prune.service`.

- [ ] **Step 4b: Prove the notify path actually fires**

Use a transient unit that fails deterministically, pointed at the same notify instance. This tests the `OnFailure` → template-unit → ntfy chain without depending on how rustic reconciles a CLI `--password` against the profile's `password-file`:

```bash
ssh galactica.bat-boa.ts.net 'sudo systemd-run --wait --collect --unit=notify-failtest \
  --property=OnFailure=backup-notify@rustic-ovh.service \
  /run/current-system/sw/bin/false'
```

Expected: the transient unit exits non-zero, and a message titled `Backup failed on galactica: rustic-ovh` arrives at `https://ntfy.arsfeld.one/backups`.

If nothing arrives, check `journalctl -u "backup-notify@rustic-ovh.service" -n 50`. The most likely cause is `NTFY_BASIC_AUTH_B64` missing, which the `set -u` in the script reports explicitly rather than POSTing unauthenticated.

- [ ] **Step 5: Observe two scheduled cycles**

Wait two Sundays. After each:

```bash
ssh galactica.bat-boa.ts.net 'systemctl status rustic-ovh.service; sudo rustic-ovh snapshots'
```

Expected: green unit, two new snapshots per run (one per label), no ntfy alert.

- [ ] **Step 6: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add hosts/galactica/backup/rustic-ovh.nix
git commit -m "feat(galactica): enable the OVH rustic backup and prune timers"
```

---

## Task 10: Retire the Hetzner plans, secrets, and docs

Removes configuration only. **The Storage Box itself is untouched** — that is Task 11, and it is gated separately.

**Files:**
- Modify: `hosts/galactica/backup/backrest-client.nix`
- Modify: `secrets/sops/galactica.yaml`
- Modify: `docs/architecture/backup.md`
- Modify: `docs/hosts/storage.md`

**Interfaces:**
- Consumes: two green scheduled OVH cycles (Task 9 Step 5).
- Produces: a Backrest config with three plans across two repos. Gates Task 11.

- [ ] **Step 1: Confirm the precondition**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh snapshots'
```

Expected: **at least two verified OVH snapshots per label** from scheduled (not manual) runs. Do not proceed otherwise.

- [ ] **Step 2: Strip the hetzner repo and plans**

In `hosts/galactica/backup/backrest-client.nix`:

Delete the two sops secret declarations (lines 82-91):

```nix
  # rclone creds for the hetzner repos. Mode 0400 matches the previous
  # services.restic.backups hetzner profile so Backrest-as-root reads
  # are unchanged.
  sops.secrets."hetzner-webdav-env" = {
    mode = "0400";
  };
  sops.secrets."hetzner-storagebox-ssh-key" = {
    mode = "0400";
    path = "/root/.ssh/hetzner_storagebox";
  };
```

Delete the `hetzner` repo entry:

```nix
      hetzner = {
        uri = "rclone:hetzner:backups/restic";
        passwordFile = config.sops.secrets."restic-password".path;
        envFile = config.sops.secrets."hetzner-webdav-env".path;
      };
```

Delete the `hetzner-system` and `hetzner` plans:

```nix
      hetzner-system = {
        repo = "hetzner";
        paths = ["/"];
        excludes = systemExcludes;
        schedule.cron = "30 4 * * 0";
        retention = remoteRetention;
      };

      hetzner = {
        repo = "hetzner";
        paths = ["/home" "/mnt/storage"];
        excludes = userExcludes;
        schedule.cron = "30 5 * * 0";
        retention = remoteRetention;
      };
```

`systemExcludes` and `userExcludes` stay — the `pegasus-system` and `pegasus` plans still use them.

Update the file's header comment (lines 1-15) to:

```nix
# galactica as a backup *client*: three Backrest plans pushing to two repos —
# the local NAS and pegasus.
#
# The offsite tier moved to rustic: see hosts/galactica/backup/rustic-ovh.nix.
# restic has no hot/cold repository concept, so OVH Cold Archive cannot live
# inside Backrest. Backrest owns the warm tiers, rustic owns the cold one, and
# they never touch the same repo.
#
# pegasus is explicitly best-effort — it runs on old drives at the cottage and
# is not the durable copy. OVH is.
#
# Retention and exclusion lists are preserved 1:1 from the prior restic config.
# Schedules are fixed-time crons on Sunday; rustic holds the 04:30 slot the
# hetzner plans used to.
#
# Per-plan ionice for the idle-class profiles is not preserved here — Backrest
# runs one daemon with one scheduler, and per-plan I/O class requires wrapping
# BACKREST_RESTIC_COMMAND. constellation.rustic does set IOSchedulingClass=idle
# on its own units.
```

- [ ] **Step 3: Format and build**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just fmt
nix develop -c nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```

Expected: build succeeds. **Read the last line for the error count.**

- [ ] **Step 4: Confirm the plan set**

```bash
cd /home/arosenfeld/Code/nixos
nix eval .#nixosConfigurations.galactica.config.constellation.backrest.plans --apply builtins.attrNames
nix eval .#nixosConfigurations.galactica.config.constellation.backrest.repos --apply builtins.attrNames
```

Expected: `[ "local-system" "pegasus" "pegasus-system" ]` and `[ "local" "pegasus" ]`.

- [ ] **Step 5: Deploy and confirm**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c just deploy galactica
ssh galactica.bat-boa.ts.net 'sudo jq -r ".repos[].id, \"--\", .plans[].id" /var/lib/backrest/config.json'
```

Expected: no `hetzner` entries. The merge script rewrites `config.json` on every start, so the removal takes effect immediately.

- [ ] **Step 6: Drop the sops secrets**

```bash
cd /home/arosenfeld/Code/nixos
nix develop -c sops unset secrets/sops/galactica.yaml '["hetzner-webdav-env"]'
nix develop -c sops unset secrets/sops/galactica.yaml '["hetzner-storagebox-ssh-key"]'
nix develop -c sops --decrypt secrets/sops/galactica.yaml | grep -c hetzner
```

Expected: final command prints `0`.

Note these credentials are still needed to *cancel* the box in Task 11 if the console requires SSH access — if so, do Task 11 first and this step after. Decide before running, not after.

- [ ] **Step 7: Update `docs/architecture/backup.md`**

- Mermaid diagram: remove the `Hetzner["rclone:hetzner:backups/*…"]` node and the `Storage --> Hetzner` edge; add an `OVH["opendal:s3 hot+cold<br/>(rustic, eu-west-par)"]` node with a `Storage --> OVH` edge.
- "Hosts and plans" table: change storage's plans to `local-system`, `pegasus-system`, `pegasus` and add a row noting the rustic `ovh` profile with its two labels.
- Add a short section, **"Two orchestrators"**, stating: Backrest wraps restic; restic has no hot/cold concept; therefore the cold tier runs under `constellation.rustic` with its own timers and its own repo password (`rustic-ovh-password` in `galactica.yaml`, not the shared `restic-password`). Backrest owns the warm tiers, rustic owns the cold one, and they never touch the same repo.
- Repositories table: delete both `hetzner*` rows; add `ovh` → `opendal:s3` (cold `galactica-backup-cold`, hot `galactica-backup-hot`, `eu-west-par`, `DEEP_ARCHIVE`).
- Notifications section: note that both orchestrators now POST through the single `constellation.backupNotify` script — Backrest via a plan hook, rustic via `OnFailure=backup-notify@<unit>.service`.
- Retention section: add that the cold tier's monthly prune passes `--keep-pack 180d` so dead packs outlive OVH's 180-day minimum storage duration and no early-deletion penalty is ever incurred.
- Secrets section: remove `hetzner-webdav-env`; add `rustic-ovh-password` and `ovh-s3-env` (both `galactica.yaml`).
- Restore section: add the rustic path — `rustic-ovh snapshots` / `ls` / `find` need no warm-up because they read the hot repo; `rustic-ovh restore` warms packs off tape automatically via the two `aws s3api` helpers, and takes as long as OVH takes (up to 48 h).
- Add a **known limitation**: rebuilding a lost *hot* repo from cold alone is undocumented upstream and untested here. The mitigation is siting the hot bucket in OVH rather than on galactica, so it survives the disaster the cold tier exists for. Anyone tempted to move the hot repo onto local disk to save $0.20/month should read this line first.

- [ ] **Step 8: Update `docs/hosts/storage.md`**

Replace the "Backup Configuration" paragraph (around line 202-207) with:

```markdown
Galactica runs `constellation.backrest` as a client, pushing three plans
(`local-system`, `pegasus-system`, `pegasus`) to the local NAS disk and
pegasus's restic REST server, plus `constellation.rustic`'s `ovh` profile —
the durable offsite copy, on OVHcloud Cold Archive. See
`docs/architecture/backup.md`, `hosts/galactica/backup/backrest-client.nix`
and `hosts/galactica/backup/rustic-ovh.nix`.
```

(The surrounding file still says "Storage" throughout from the storage→galactica rename. Fixing that everywhere is out of scope for this plan; this paragraph uses the current name.)

- [ ] **Step 9: Confirm no Hetzner remnants**

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "hetzner" --include=*.nix --include=*.md . | grep -v docs/superpowers/
ssh galactica.bat-boa.ts.net 'systemctl list-timers --all | grep -i hetzner || echo "no hetzner timers"'
ssh galactica.bat-boa.ts.net 'ls /run/secrets/ | grep -i hetzner || echo "no hetzner secrets"'
```

Expected: no matches outside `docs/superpowers/` (the spec and this plan legitimately mention it), no timers, no secrets.

- [ ] **Step 10: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add hosts/galactica/backup/backrest-client.nix secrets/sops/galactica.yaml \
        docs/architecture/backup.md docs/hosts/storage.md
git commit -m "feat(galactica): retire the Hetzner backup tier in favour of OVH Cold Archive"
```

---

## Task 11: Cancel the Hetzner Storage Box

**⚠ Destructive and irreversible. Requires explicit operator confirmation at the time — not implied by having reached this task.**

**Files:** none.

**Interfaces:**
- Consumes: a passed restore drill (Task 8) and a completed Task 10.

- [ ] **Step 1: State plainly what is destroyed**

Cancelling Storage Box `u547717` (BX21) permanently destroys **1.9 TB**:

| Path | Size | What it is |
|---|---|---|
| `backups/restic` | 1.7 TiB | user data — `/home` + `/mnt/storage`; **replaced by the OVH `user` snapshots** |
| `backups/restic-system` | 171 GiB | system — `/`; **replaced by the OVH `system` snapshots** |
| `data/` | 101 GB | orphaned restic REST repo whose `index/`, `keys/` and `snapshots/` were all emptied 2026-02-18. Dead packs. **Nothing recoverable — verify this claim below before accepting it.** |
| `restic/` | 63 KB | stale, empty |

- [ ] **Step 2: Re-verify the orphaned repo really is dead**

Do not take the spec's word for it at the moment of deletion.

```bash
ssh galactica.bat-boa.ts.net 'sudo bash -c "
  set -a; . /run/secrets/hetzner-webdav-env; set +a
  for d in data restic; do
    echo \"== \$d\"
    rclone lsf hetzner:\$d/snapshots | head
    rclone lsf hetzner:\$d/index | head
    rclone lsf hetzner:\$d/keys | head
  done
"'
```

Expected: all three listings empty for both. **If `snapshots/` or `keys/` has any content, STOP** — that repo may still be restorable and the spec's assessment is wrong.

(If the secrets were already removed in Task 10 Step 6, re-add them temporarily or run this from the Hetzner console instead.)

- [ ] **Step 3: Confirm the replacement one more time**

```bash
ssh galactica.bat-boa.ts.net 'sudo rustic-ovh snapshots && sudo rustic-ovh check'
```

Expected: snapshots for both labels from scheduled runs; `check` clean.

- [ ] **Step 4: Ask the operator**

Present Steps 1-3 and ask for explicit confirmation to cancel. **Do not proceed without it.** If the answer is anything other than a clear yes, stop here — the box costs €10.90/month to keep, which buys unlimited thinking time.

- [ ] **Step 5: Cancel (operator, Hetzner console)**

Robot / Storage Box → `u547717` → cancel. Note the effective date; Hetzner typically runs to the end of the billing period.

- [ ] **Step 6: Confirm the saving**

Check the next invoice against the OVH bill. Expected: Hetzner ~€10.90/mo gone; OVH ~$3.93/mo cold + $0.16-0.41/mo hot. Net ≈ €7/month, ≈ €84/year.

The hot-metadata figure was the least certain number in the design (extrapolated from the local repo's 239 MB `index/` at 488 GiB, plus an allowance for tree packs). Record the actual first-month OVH bill in the "Execution log" — it is now measurable.

---

## Execution log

_Append results here as tasks complete: bucket layout and storage classes (Task 5), parity-gate numbers and the explained delta (Task 6), seed durations and transferred bytes (Task 7), restore-drill timings and the retrieval-fee answer (Task 8), first-month OVH bill (Task 11)._

### Task 5 (2026-07-27)

Deploy succeeded (`Activation successful`, secrets `ovh-s3-env` and `rustic-ovh-password` landed). `/etc/rustic/ovh.toml` present; `rustic-ovh.service` and `rustic-ovh-prune.service` present with no `rustic-ovh.timer`, as expected. Note: `systemctl list-unit-files` reports their state as `linked`, not `static` as this task's brief predicted — `systemctl cat` shows the unit content is correct (proper `OnFailure=... backup-notify@rustic-ovh.service` wiring), so this looks like a harmless terminology difference from how these units are installed, not a functional problem.

`rustic-ovh init` created repository `93b94ff6`, key `8d590476`. `rustic-ovh backup --label smoke /etc/os-release /etc/machine-id` saved snapshot `3ba659c2` (2 files, 615 B raw, 1.4 KiB added).

**Storage-class gate (Step 5) — PASS.** Every object under `galactica-backup-cold`'s `data/` prefix reads `StorageClass: DEEP_ARCHIVE`, including both real packs — `data/d4/d416139a...` (the tree pack, also mirrored into the hot bucket as `STANDARD`) and `data/fd/fd3bb835...` (the file-content pack). No `STANDARD` rows anywhere. `default_storage_class = "DEEP_ARCHIVE"` in `options-cold` is being honoured.

**Bucket layout (Step 6) — more nuanced than the brief's summary.** Both buckets carry a full metadata mirror: `config` ×1, `keys` ×2, `index` ×2, `snapshots` ×2 in *both* `galactica-backup-hot` and `galactica-backup-cold` (cold is the authoritative full repo; hot is rustic's fast-access metadata replica). Both buckets also have a `data/` prefix, but the objects inside differ by storage class, not by path: the hot bucket's single tree pack (`data/d4/d416139a...`) is `STANDARD`; the cold bucket's two content packs are `DEEP_ARCHIVE`. Confirms metadata operations (`snapshots`, `ls`, `find`, `check` without `--read-data`) never touch tape — only actual file-content packs are cold.

`rustic-ovh snapshots` (Step 7) returned the smoke snapshot in 1.58s wall-clock, no warm-up log lines — metadata reads need no tape warm-up, as designed.

**Step 8 did not match the brief's predicted outcome.** `rustic-ovh forget --filter-label smoke --keep-none` reported `Action: keep, Reason: daily/weekly/monthly` and `nothing to remove` — the smoke snapshot is still present. Root cause (confirmed via `--dry-run`): the `ovh` profile's `[forget]` block (`keep-daily = 7`, `keep-weekly = 4`, `keep-monthly = 6`) is merged additively with CLI retention flags rather than overridden by `--keep-none`; since it's the only snapshot in its (host, label, paths) group it always satisfies "most recent daily/weekly/monthly", so it's always kept. A dry-run with `--filter-label smoke --keep-none --keep-daily 0 --keep-weekly 0 --keep-monthly 0` does show `Action: remove`, confirming the mechanism but not executed for real, per instructions to stop rather than improvise past what the brief specified verbatim. No `--prune` was run at any point.

**Resolved.** `sudo rustic-ovh forget 3ba659c2` removed it — rustic logged `Action: remove, Reason: if argument`, and `rustic-ovh snapshots` now returns `total: 0 snapshot(s)`. Forgetting by explicit id bypasses the retention policy entirely, which is why it works where `--keep-none` did not. Step 8 of this plan has been rewritten to that form. Still no `--prune`: the two smoke data packs (kilobytes) stay on tape past their 180-day floor, as everything else will.

**Deferred Task 1 verifications:**
- `systemctl cat "backup-notify@rustic-ovh.service"` shows the literal template with unexpanded `%i` (expected — `cat` never expands specifiers). `systemctl show "backup-notify@rustic-ovh.service" -p Description -p ExecStart` confirms the *resolved* values: `Description=ntfy notification for failed backup unit rustic-ovh`, and `ExecStart` with all three `%i` occurrences correctly resolved to `rustic-ovh` (including `journalctl -u rustic-ovh`).
- End-to-end ntfy delivery: ran `backup-notify` (`/nix/store/a2ihj955hcw62f5nc0d89rnwma9hvvmm-backup-notify`) directly with `ntfy-publisher-env` sourced. Exit 0; ntfy responded `{"id":"aSL2T37vsIqO", ... "topic":"backups", "title":"backup-notify smoke test", ...}`. Message delivery to https://ntfy.arsfeld.one/backups awaits human confirmation.

### Task 5 addendum — storage classes are not split the way the design assumed

The design said "hot repo holds metadata, cold holds data packs". The truth, measured:

| Bucket | `config`/`keys`/`index`/`snapshots` | `data/` |
|---|---|---|
| `galactica-backup-cold` | `DEEP_ARCHIVE` | `DEEP_ARCHIVE` |
| `galactica-backup-hot` | `STANDARD` | `STANDARD` |

Object counts are point-in-time and small here, so read the table as being about *storage class*,
not volume. The `data/` prefix in the hot bucket held 258 objects at measurement, but 257 of those
were zero-byte prefix markers — only one, at 1146 bytes, was a real tree pack.

**The cold bucket is a complete, self-contained rustic repository, entirely on tape.** The hot
bucket is a Standard-class replica of everything cacheable. Reads are served from hot, which is why
`snapshots` returns in ~1.5 s with no warm-up — that part of the design holds exactly as intended.

Measurements behind the table — all four cells, via
`aws s3api list-objects-v2 --bucket <b> --prefix <p> --query 'Contents[].StorageClass'`:

| Query | Result |
|---|---|
| cold, `config` / `keys` / `index` / `snapshots` | `DEEP_ARCHIVE` on every object |
| cold, `data/` | `DEEP_ARCHIVE` on every object (Step 5's gate, above) |
| hot, `config` / `keys` / `index` / `snapshots` | `STANDARD` on every object |
| hot, `data/` | 258 rows, all `STANDARD` |

Two consequences the design did not state:

- **A lost hot repo is probably recoverable from cold — but this is untested and there is no tooling
  for it.** Cold carries the full metadata mirror, so the bytes needed to rebuild the hot bucket
  demonstrably exist. Three caveats before anyone relies on that in an actual disaster:
  1. **The warm-up scripts cannot do it.** `rustic-ovh-warm-up` and `-wait` build their S3 keys as
     `data/<first-2-hex>/<id>` from rustic-supplied pack ids. They have no way to address
     `config`, `keys`, `index` or `snapshots` objects. Recovery would need warming those keys by
     hand with `aws s3api restore-object` before rustic could read anything.
  2. **Nobody has tried it**, not even at smoke scale. "The objects are present" is not the same
     claim as "rustic reconstructs a hot repo from them".
  3. **The cost is unquantified** — see the still-open retrieval-fee question in Task 8 Step 1.
     Whether OVH charges a per-GB retrieval fee on top of the restored copy's Standard-rate billing
     is unconfirmed, and a full-metadata restore is exactly where that would show up.

  So: siting the hot bucket in OVH rather than on galactica remains the right call, and this is a
  plausible fallback behind it — not a rehearsed procedure. Treat it as such.
- **Cold stores a second copy of the metadata**, adding roughly 20-50 GB at $0.002/GB — a few cents
  a month on top of the estimate. Cheap, and it is what makes the above possible at all.
