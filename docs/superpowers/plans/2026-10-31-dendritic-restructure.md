# Dendritic Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the flake into the dendritic pattern — import-tree loads `modules/`, shared features are `flake.modules.nixos.<feature>` turned on by importing them, each host declares itself and its metadata in `modules/hosts/<name>.nix` — and remove `with lib;`, without changing any host's system closure.

**Architecture:** Staged. `with lib` goes first. Then import-tree is bootstrapped beside a haumea-loaded `modules/_legacy/` and a typed `configurations.nixos` option fed from the old `hosts/` discovery. Features then move out of `_legacy/` one group at a time. Hosts then move one at a time. Finally the scaffolding is removed. Every commit is proved closure-neutral with `scripts/dendritic/verify.sh`.

**Tech Stack:** Nix flakes, flake-parts (+ `flakeModules.modules`), import-tree, NixOS module system, alejandra, Python 3 (migration tooling only).

**Spec:** `docs/superpowers/specs/2026-10-31-dendritic-restructure-design.md`

## Global Constraints

- **Closure-neutral, every commit.** `scripts/dendritic/verify.sh check` must print `MATCH` for every host and `MATCH flake outputs`. `LOOSE-ONLY` is accepted only after running the printed `explain` command and confirming that every change it lists reorders entries whose order means nothing (a kernel cmdline whose parameters are all distinct, an unordered set). Order that *does* mean something gets an explicit `lib.mkBefore`/`lib.mkAfter`/`lib.mkOrder`. Examples: `nixpkgs.overlays`, PATH-like lists, a kernel parameter given twice. A `DIFF` is explained and fixed before committing, never waved through. One exception, and only this one: a `DIFF` whose `explain` output consists solely of a source directory captured whole with `${./.}` or `src = ./.` changing because a `.nix` file inside that directory was edited (and everything downstream of it) is accepted; name it in the commit message. Known cases: `stash-identify`, `plab` and `vault-grab` under galactica's services (Task 18). The three `packages/` files with `src = ./.` (telequebec-archiver, natpmp-server, network-metrics-exporter) keep `with lib;` instead, to avoid rebuilding them.
- **After accepting a `LOOSE-ONLY`, promote the checked state:** `cp /var/tmp/dendritic/check/* /var/tmp/dendritic/baseline/` once every host has been checked at the commit, so the next task compares against the accepted state instead of re-reporting the same reordering. Record what was accepted in the commit message.
- **Stage only your own files.** Other sessions commit to this repo concurrently; never `git add -A` at the repo root, check `git status` before committing, and leave changes you did not make alone.
- **One host at a time.** Never evaluate several hosts in parallel; parallel toplevel evaluations have run raider out of memory. `verify.sh` already runs them sequentially under `nice`.
- **New files are invisible to the flake until tracked.** `git add` (or `git add -N`) every new file and every `git mv` before any `nix eval`.
- **Commit straight to `master`.** No branches, no worktrees. Conventional commits, `<type>(<scope>): <subject>`, scope `modules` or a host name. Never mention Claude.
- **Format before committing:** `just fmt` must leave no diff.
- **Never run `nix flake check`, and never build or evaluate cylon-link's toplevel.** Evaluating cylon-link builds its armv7l cross toolchain (import-from-derivation), and `nix flake check` evaluates every host and the `cylon-link-config` check. `verify.sh check` compares cylon-link on a dump of evaluated settings with import-from-derivation disabled, and evaluates every other flake check. The checks are built in CI on push (`checks.yml`), and locally only where a task names one.
- **Feature key convention:** every `flake.modules.nixos.<feature>` definition is `{key = "modules/<file path under modules/ without .nix>"; imports = [<module>];}`. `dendritic.py wrap --key` writes it. One key per file, never shared between files.
- **Feature imports from the flake-parts side:** inside a feature or host file, refer to features through `let features = config.flake.modules.nixos; in`, where `config` is the *flake-parts* module argument, bound in the file's outer function. The inner NixOS module has its own `config`, which shadows the outer one inside it. That's why the `let` sits outside.
- **Do not edit** `.github/workflows/*`, justfile recipes (only the one hard-coded path in Task 12), `packages/`, `overlays/` or `infra/` beyond what a task names.
- No deploy at any point. Identical closures mean identical systems.

## Tooling (already committed in `scripts/dendritic/`)

Validated while planning. The fingerprint was tested on octopi: a comment-only edit gives `MATCH`, an added `environment.etc` entry gives `DIFF` (`explain` names `etc-probe`), and a reordered `kernelParams` gives strict `DIFF` but loose `MATCH`. `wrap`/`hide`/`fixpaths` were run over a scratch copy of all ten host trees: all 158 files parse afterwards and every relative path resolves.

| tool | use |
|---|---|
| `verify.sh baseline` / `verify.sh check [host...]` | the per-commit proof described above, plus evaluation of every flake check except `cylon-link-config`; cylon-link is compared on `cylon-link-settings.nix` (evaluated settings, import-from-derivation off) instead of a fingerprint; data in `/var/tmp/dendritic/` |
| `fingerprint.py explain …` | the command `verify.sh` prints next to a non-`MATCH` host: lists the derivations whose own content changed, field by field |
| `dendritic.py unwith FILE…` | delete `with lib;` and prefix each name it supplied with `lib.` (Nix reports undefined names at parse time; the tool parses until none are left) |
| `dendritic.py reach DIR` | `.nix` files in a host dir that its `configuration.nix` never imports as a module (helpers, tests, dead files) |
| `dendritic.py hide DIR` | `git mv` each of those to a `_` name (a `default.nix` hides its whole directory) and repoint references inside DIR |
| `dendritic.py fixpaths OLD NEW` | after `git mv OLD NEW`, repoint relative paths that left the moved tree |
| `dendritic.py checkpaths FILE…` | relative path literals that no longer resolve after a move |
| `dendritic.py wrap --root R --into ATTR [--key K] FILE…` | rewrite NixOS module files as flake-parts modules defining ATTR; moves `self`/`inputs` to the outer function; drops `imports` entries resolving inside R; deletes files that only imported siblings; reports `SKIPPED` for anything it cannot do safely |
| `enabled.nix` | per-host enabled-feature table (Task 0); works only before Task 3 |

All commands run from the repo root, `~/Code/nixos`.

## Enabled-feature table (captured 2026-10-31, re-captured in Task 0)

`Y` on, `.` off, `-` option absent, numbers are service counts.

```
feature                   basest blackb cylon- galact octopi pegasu r2s    raider raspi3 router
@blocky                   .      .      .      .      .      .      .      .      .      .
@caddy                    Y      .      .      Y      .      Y      .      .      .      Y
@check-stock              .      .      .      Y      .      .      .      .      .      .
@cloudflared              .      .      .      Y      .      Y      .      .      .      .
@gamemode                 .      Y      .      .      .      .      .      Y      .      .
@media.gateway.services   2      0      0      56     0      6      0      0      0      0
@media.services           2      0      0      66     0      7      0      0      0      0
@pantheon                 .      Y      .      .      .      .      .      Y      .      .
@tsnsrv                   Y      .      .      Y      Y      Y      .      Y      Y      .
@tsnsrv-sidecars          .      .      .      .      .      .      .      .      .      .
backrest                  Y      .      .      Y      .      Y      .      Y      .      .
backupNotify              Y      .      .      Y      .      Y      .      Y      .      .
backupStatus              Y      .      .      Y      .      Y      .      Y      .      .
backupSummary             .      .      .      Y      .      .      .      .      .      .
common                    Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
desktop                   .      Y      .      .      .      .      .      Y      .      .
development               .      Y      .      Y      .      .      .      Y      .      .
email                     Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
forgejo-runner            .      .      .      Y      .      .      .      .      .      .
gaming                    .      Y      .      .      .      .      .      Y      .      .
mediaSync                 -      -      -      -      -      .      -      -      -      -
netdataClient             Y      Y      .      .      Y      Y      Y      Y      Y      .
podman                    Y      .      .      Y      .      Y      .      .      .      Y
sops                      Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
users                     Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
virtualization            Y      Y      .      Y      Y      Y      Y      Y      Y      .
vpnExitNodes              -      -      -      .      -      -      -      -      -      -
```

Resulting feature imports (base is automatic and not listed):

| feature | hosts |
|---|---|
| `tsnsrv` | basestar galactica octopi pegasus raider raspi3 (and through `media`) |
| `media` | basestar galactica pegasus raider router (raider sets `media.config`; router through `podman`, which reads `media.containers`) |
| `check-stock` | galactica |
| `blocky` | none (exported, unused) |
| `podman` | basestar galactica pegasus router |
| `virtualization` | basestar blackbird galactica octopi pegasus r2s raider raspi3 |
| `netdata-client` | basestar blackbird octopi pegasus r2s raider raspi3 |
| `development` | blackbird galactica raider |
| `forgejo-runner` | galactica |
| `backrest` | basestar galactica pegasus raider (imports `backup-notify`, `backup-status`) |
| `backup-summary` | galactica |
| `desktop` | blackbird raider (imports `pantheon-dock`, `pantheon-gamemode`) |
| `gaming` | blackbird raider |

`mediaSync` (pegasus) and `vpnExitNodes` (galactica) are host-local and keep their flags.

---

### Task 0: Baseline

**Files:** none changed.

**Interfaces:**
- Produces: `/var/tmp/dendritic/baseline/{<host>.fp,<host>.loose,<host>.drv,<host>.json.zst,outputs.txt}` and `/var/tmp/dendritic/enabled.txt`, which every later task compares against.

- [ ] **Step 1: Confirm a clean tree at the tooling commit**

Run: `git status --short && git log --oneline -1`
Expected: no output from status; HEAD is the plan commit (`docs(modules): plan the dendritic restructure`).

- [ ] **Step 2: Record the baseline**

Run: `scripts/dendritic/verify.sh baseline`
Expected: `recorded    <host>` for all ten hosts, in order basestar … router. Takes a while; do not interrupt.

- [ ] **Step 3: Re-capture the enabled table**

```bash
for h in $(nix eval --json .#hosts | jq -r '.[]'); do
  printf '%s ' "$h"
  nice nix eval --json --impure --expr "import ./scripts/dendritic/enabled.nix (builtins.getFlake (toString ./.)) \"$h\""
  echo
done > /var/tmp/dendritic/enabled.txt
```

Compare with the table above (render it the same way if useful). If any value differs, stop and update the "Resulting feature imports" table before continuing. That table is what every later task follows.

- [ ] **Step 4: Save the table next to the spec**

Write `docs/superpowers/specs/2026-10-31-dendritic-restructure-enabled.md` with a one-line intro ("Per-host enabled features at the start of the dendritic restructure, from `scripts/dendritic/enabled.nix`; drives which hosts import each feature.") and the table above in a fenced block.

```bash
git add docs/superpowers/specs/2026-10-31-dendritic-restructure-enabled.md
git commit -m "docs(modules): record per-host enabled features before the dendritic move"
```

---

### Task 1: Remove `with lib`

**Files:**
- Modify: the 40 files from `grep -rlE "with lib;" --include=*.nix hosts modules packages`, **minus** `hosts/router/xdp-firewall.nix`. That one does not parse and nothing imports it; Task 12 hides it.

- [ ] **Step 1: Run the converter**

```bash
files=$(grep -rlE "with lib;" --include=*.nix hosts modules packages | grep -v '^hosts/router/xdp-firewall.nix$')
python3 -I scripts/dendritic/dendritic.py unwith $files
```

Expected: one `unwith <file>: N names prefixed` line per file, and no `SKIPPED`. A file showing `0 names prefixed` used nothing from `with lib`; deleting the statement was all it needed.

- [ ] **Step 2: Confirm nothing module-scoped is left**

Run: `grep -rnE "with lib;" --include=*.nix hosts modules packages`
Expected: only `hosts/router/xdp-firewall.nix`. `with lib.kernel;` and similar scoped forms do not match this pattern and stay.

- [ ] **Step 3: Format, verify, check**

```bash
just fmt
scripts/dendritic/verify.sh check
```

Expected: `MATCH` for all ten hosts, `MATCH flake outputs`, and `OK flake checks evaluate`.

- [ ] **Step 4: Commit**

```bash
git add -A hosts modules packages
git commit -m "refactor(modules): replace with lib; by explicit lib. prefixes"
```

---

### Task 2: Bootstrap import-tree, `modules/flake/`, `_legacy/` and the host option

**Files:**
- Modify: `flake.nix` (inputs + outputs), `flake.lock`
- Move: `modules/*` → `modules/_legacy/*`; `flake-modules/` → `modules/flake/`
- Create: `modules/flake/systems.nix`
- Rewrite: `modules/flake/hosts.nix` (whole file)
- Modify: `modules/flake/lib.nix` (haumea `src`, drop `lightHosts`)
- Modify: `modules/_legacy/media/gateway.nix:25`, `modules/_legacy/media/containers.nix:27` (`${self}/modules/media/__utils.nix` → `./__utils.nix`)
- Modify: `tests/pantheon-dock-test.nix:14`, `tests/pantheon-gamemode-test.nix:27`, `tests/router-test.nix` (the `caddy-security.nix` line)

**Interfaces:**
- Produces: flake-parts option `configurations.nixos.<name>` = `{ module :: deferredModule; nixpkgs :: "stable"|"unstable" = "stable"; homeManager :: bool = true; tier :: nullOr str = null; ci :: bool = true; }`.
- Produces: in `modules/flake/hosts.nix`, the `legacy` attrset (host → metadata) and `legacyFeatures` attrset (host → list of feature names) that Tasks 3–9 extend and Tasks 10–19 empty.
- Produces: flake outputs `hosts`, `tiers`, `unstableHosts`, `lightHosts` (new top-level output, sorted), `ciExcludedHosts`, `ciMatrix`, `nixosConfigurations`. `lib.lightHosts` is removed.
- Produces: flake output `modules` (from `flake.modules`), empty until Task 3.

- [ ] **Step 1: Add the import-tree input**

In `flake.nix`, after the `haumea` lines, add:

```nix
    import-tree.url = "github:vic/import-tree"; # Loads every .nix file under modules/ as a flake-parts module
```

Run: `nix flake lock`
Expected: `• Added input 'import-tree'` and no other input changes (`git diff flake.lock` touches only `import-tree` and `root.inputs`).

- [ ] **Step 2: Move the NixOS module tree into `_legacy/`**

```bash
mkdir modules/_legacy
for f in modules/*; do [ "$f" = modules/_legacy ] || git mv "$f" modules/_legacy/; done
python3 -I scripts/dendritic/dendritic.py fixpaths modules modules/_legacy
```

Expected: `rewrote` lines for files whose `../` paths (to `packages/`, `common/`, `secrets/` …) needed one more level. Then:

Run: `python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/_legacy -name '*.nix')`
Expected: no `DANGLING` lines.

- [ ] **Step 3: Make the media helper import relative**

In `modules/_legacy/media/gateway.nix` and `modules/_legacy/media/containers.nix`, replace

```nix
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib pkgs;};
```

with

```nix
  utils = import ./__utils.nix {inherit config lib pkgs;};
```

(Same file, same evaluation; it simply stops depending on where `modules/` sits inside `self`.)

- [ ] **Step 4: Move the flake modules**

```bash
git mv flake-modules modules/flake
python3 -I scripts/dendritic/dendritic.py fixpaths flake-modules modules/flake
python3 -I scripts/dendritic/dendritic.py checkpaths modules/flake/*.nix
```

Expected: `rewrote` for `checks.nix`, `dev.nix`, `images.nix`, `infra.nix`, `lib.nix`, `hosts.nix`; then no `DANGLING`.

- [ ] **Step 5: Point haumea at `_legacy` and drop `lightHosts` from `lib`**

In `modules/flake/lib.nix`, fixpaths rewrote haumea's `src = ../modules;` to `src = ..;` (the `modules/` directory is now the parent). Change it to:

```nix
            src = ../_legacy;
```

Delete the line `    lightHosts = ["raspi3" "octopi" "r2s" "cylon-link"];` and the `lightHosts` entry in the `inherit` list below it.

- [ ] **Step 6: Replace `flake.nix` outputs**

Replace the whole `outputs = …;` with:

```nix
  # Every .nix file under modules/ is a flake-parts module, except paths with a
  # `/_` component. See modules/flake/ for the flake's own wiring.
  outputs = inputs: inputs.flake-parts.lib.mkFlake {inherit inputs;} (inputs.import-tree ./modules);
```

Create `modules/flake/systems.nix`:

```nix
{inputs, ...}: {
  # flake.modules.<class>.<name>: the features hosts import
  # (docs/superpowers/specs/2026-10-31-dendritic-restructure-design.md).
  imports = [inputs.flake-parts.flakeModules.modules];

  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
}
```

- [ ] **Step 7: Rewrite `modules/flake/hosts.nix`**

```nix
{
  config,
  lib,
  self,
  inputs,
  ...
}: let
  hosts = config.configurations.nixos;
  features = config.flake.modules.nixos;

  # Hosts still under hosts/<name>/, not yet moved to modules/hosts/<name>.nix.
  # Their settings live here until each moves; then the entry is deleted.
  legacy = {
    basestar = {tier = "tier1";};
    blackbird = {};
    # CI never builds this host. It is cross-compiled for armv7l and its kernel
    # alone outlasts the build job's 120-minute timeout on a GitHub runner.
    # raider builds it in `just deploy` phase 1 instead.
    cylon-link = {
      homeManager = false;
      ci = false;
    };
    galactica = {tier = "tier1";};
    octopi = {homeManager = false;};
    pegasus = {};
    r2s = {homeManager = false;};
    raider = {
      nixpkgs = "unstable";
      tier = "tier1";
    };
    raspi3 = {homeManager = false;};
    router = {};
  };

  # Features each legacy host imports, by name in flake.modules.nixos. base is
  # added to every host by mkLinuxSystem and is not listed.
  legacyFeatures = {};

  legacyHosts = lib.filterAttrs (name: _: builtins.pathExists ../../hosts/${name}/configuration.nix) legacy;
in {
  options.configurations.nixos = lib.mkOption {
    description = "NixOS hosts. Each becomes nixosConfigurations.<name>.";
    default = {};
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options = {
        module = lib.mkOption {
          type = lib.types.deferredModule;
          description = "The host's NixOS configuration.";
        };
        nixpkgs = lib.mkOption {
          type = lib.types.enum ["stable" "unstable"];
          default = "stable";
          description = "The nixpkgs (and matching home-manager) the host is built from.";
        };
        homeManager = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the host gets home-manager and home/home.nix.";
        };
        tier = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Deployment tier, selected by `just deploy @<tier>`.";
        };
        ci = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether CI builds the host (membership of ciMatrix).";
        };
      };
    });
  };

  config = {
    configurations.nixos =
      lib.mapAttrs (name: meta:
        meta
        // {
          module.imports =
            lib.optional (builtins.pathExists ../../hosts/${name}/disko-config.nix) inputs.disko.nixosModules.disko
            ++ map (f: features.${f}) (legacyFeatures.${name} or [])
            ++ [../../hosts/${name}/configuration.nix];
        })
      legacyHosts;

    flake = {
      hosts = builtins.attrNames hosts;

      # Exposed as the `tiers` flake output; the justfile's @tier selectors
      # and the README table read it.
      tiers =
        lib.foldlAttrs (acc: name: h:
          if h.tier == null
          then acc
          else acc // {${h.tier} = (acc.${h.tier} or []) ++ [name];})
        {}
        hosts;

      unstableHosts = builtins.attrNames (lib.filterAttrs (_: h: h.nixpkgs == "unstable") hosts);
      lightHosts = builtins.attrNames (lib.filterAttrs (_: h: !h.homeManager) hosts);
      ciExcludedHosts = builtins.attrNames (lib.filterAttrs (_: h: !h.ci) hosts);

      # CI build matrix, with auto-detected platforms. Consumed by
      # .github/workflows/build.yml via `nix eval`. aarch64 hosts build on
      # GitHub's free native ARM runners (public repo) instead of slow QEMU
      # emulation, which used to time out at 2h.
      ciMatrix =
        map (hostName: let
          platform = self.nixosConfigurations.${hostName}.config.nixpkgs.hostPlatform.system;
        in {
          host = hostName;
          inherit platform;
          runner =
            if platform == "aarch64-linux"
            then "ubuntu-24.04-arm"
            else "ubuntu-latest";
        })
        (builtins.filter (name: hosts.${name}.ci) (builtins.attrNames hosts));

      nixosConfigurations =
        lib.mapAttrs (name: h: let
          unstable = h.nixpkgs == "unstable";
        in
          self.lib.mkLinuxSystem {
            enableHomeManager = h.homeManager;
            nixpkgsInput =
              if unstable
              then inputs.nixpkgs-unstable
              else inputs.nixpkgs;
            homeManagerInput =
              if unstable
              then inputs.home-manager-unstable
              else inputs.home-manager;
            mods = [h.module];
          })
        hosts;
    };
  };
}
```

- [ ] **Step 8: Repoint the tests that import module files by path**

- `tests/pantheon-dock-test.nix`: `../modules/constellation/pantheon-dock` → `../modules/_legacy/constellation/pantheon-dock`
- `tests/pantheon-gamemode-test.nix`: `../modules/constellation/pantheon-gamemode.nix` → `../modules/_legacy/constellation/pantheon-gamemode.nix`
- `tests/router-test.nix`: `"${self}/modules/constellation/caddy-security.nix"` → `"${self}/modules/_legacy/constellation/caddy-security.nix"`

Run: `grep -rnE '(\.\./|\$\{self\}/)modules/(constellation|media|security|tsnsrv|blocky|check-stock|cloudflared|systemd)' --include=*.nix . | grep -v '^./docs'`
Expected: no output.

- [ ] **Step 9: Track, format, verify**

```bash
git add -A flake.nix flake.lock modules tests
just fmt
scripts/dendritic/verify.sh check
```

Expected: `MATCH` for all ten hosts and `MATCH flake outputs`. The `lightHosts` line in `outputs.txt` was taken from `lib.lightHosts` at baseline and from the new top-level output now; both are sorted, so they compare equal. Also run `nix eval --json .#modules` → `{}` (no features yet), and `nix eval .#lib.lightHosts` → error (removed).

- [ ] **Step 10: Commit**

```bash
git commit -m "refactor(modules): load modules/ with import-tree, typed configurations.nixos option"
```

---

### Task 3: `base` feature

**Files:**
- Move to `modules/base/`: `_legacy/constellation/{common,users,sops,email,caddy-security}.nix`, `_legacy/constellation/certs/`, `_legacy/systemd-email-notify.nix`, `_legacy/cloudflared.nix`, `_legacy/security/brotli-cve-2026-111497.nix`, `_legacy/security/__replace-direct-dependencies.nix`, `_legacy/security/nar-restore.py`
- Modify: `modules/flake/lib.nix` (`baseModules` adds `features.base`)
- Modify: every host line that sets `constellation.{common,users,sops,email}.enable`
- Modify: `tests/router-test.nix` (the caddy-security import)

**Interfaces:**
- Consumes: `configurations.nixos`, `legacyFeatures` (Task 2).
- Produces: `flake.modules.nixos.base`, defined across the files above, each with `key = "modules/base/<file>"`. Every host gets it from `mkLinuxSystem`.

- [ ] **Step 1: Move**

```bash
mkdir -p modules/base
git mv modules/_legacy/constellation/{common,users,sops,email,caddy-security}.nix modules/_legacy/constellation/certs modules/base/
git mv modules/_legacy/systemd-email-notify.nix modules/_legacy/cloudflared.nix modules/base/
git mv modules/_legacy/security/brotli-cve-2026-111497.nix modules/_legacy/security/__replace-direct-dependencies.nix modules/_legacy/security/nar-restore.py modules/base/
python3 -I scripts/dendritic/dendritic.py checkpaths modules/base/*.nix
```

Fix every `DANGLING` by hand. Files from `_legacy/constellation/` and `_legacy/security/` moved up one directory, so each `../` path from them loses one `../`; files from `_legacy/` itself kept their depth. Recompute each path from the file's new directory and re-run until clean. Then `rmdir modules/_legacy/security` if empty.

- [ ] **Step 2: Wrap each file with its own key**

```bash
for f in common users sops email caddy-security systemd-email-notify cloudflared brotli-cve-2026-111497; do
  python3 -I scripts/dendritic/dendritic.py wrap --root modules --into flake.modules.nixos.base --key "modules/base/$f" "modules/base/$f.nix"
done
```

Expected: no `SKIPPED`. `__replace-direct-dependencies.nix` is a helper called with arguments, and its `/_` prefix keeps import-tree off it. Do not wrap it.

- [ ] **Step 3: Remove the four enable switches**

In each of `common.nix`, `users.nix`, `sops.nix`, `email.nix`: delete the `enable` option from `options.constellation.<name>` and replace `config = lib.mkIf cfg.enable {` with `config = {` (keep the closing brace). If a file uses `lib.mkMerge [ (lib.mkIf cfg.enable {...}) … ]`, unwrap only the `cfg.enable` condition. Leave every other option alone.

Find the setters and delete them (inside an attrset, delete only the `enable = …;` line):

Run: `grep -rnE "(constellation\.)?(common|users|sops|email)\.enable\s*=|^\s*(common|users|sops|email)\.enable\s*=" hosts modules`
Expected after editing: no output. Known setters: `constellation.sops.enable = true;` in basestar, blackbird (`sops.enable`), cylon-link, galactica, octopi, r2s, raider, raspi3, router; `sops`, `common`, `email` `.enable = true;` in `hosts/pegasus/configuration.nix:20-22`.

- [ ] **Step 4: Add base to every host**

In `modules/flake/lib.nix`, add `config` to the module's arguments (`{config, self, inputs, ...}:`) and, in `baseModules`, insert immediately before the `# Load all modules from the modules directory` haumea block:

```nix
      # Features every host has; see modules/base/.
      config.flake.modules.nixos.base
```

- [ ] **Step 5: Repoint the router test**

In `tests/router-test.nix`, replace the import line `"${self}/modules/_legacy/constellation/caddy-security.nix"` with

```nix
        # base/caddy-security.nix is a flake-parts module defining part of `base`.
        (import "${self}/modules/base/caddy-security.nix").flake.modules.nixos.base
```

(The file takes no outer arguments; if `wrap` gave it an outer `{self, ...}:`, call it with `{inherit self inputs;}`.)

- [ ] **Step 6: Track, format, verify**

```bash
git add -A modules hosts tests
just fmt
scripts/dendritic/verify.sh check
```

Expected: `MATCH` (or a `LOOSE-ONLY` whose `explain` is pure reordering, per Global Constraints) for all hosts, and `MATCH flake outputs`. `nix eval --json .#modules.nixos --apply builtins.attrNames` → `["base"]`.

If a host fails to evaluate with `The option 'constellation.<x>' does not exist`, a setter was missed. If one fails with `attribute '<x>' missing` for a legacy module, that module reads an option of something that moved: check the move list.

- [ ] **Step 7: Commit**

```bash
git commit -m "refactor(modules): base feature for every host, imported instead of enabled"
```

---

### Task 4: `tsnsrv`, `media`, `check-stock`, `blocky`

**Files:**
- Move: `_legacy/tsnsrv.nix` → `modules/tsnsrv.nix`; `_legacy/check-stock.nix` → `modules/check-stock.nix`; `_legacy/blocky.nix` → `modules/blocky.nix`; `_legacy/media/` → `modules/media/`
- Modify: `modules/flake/hosts.nix` (`legacyFeatures`)

**Interfaces:**
- Produces: `flake.modules.nixos.tsnsrv`, `.media` (four files, keys `modules/media/{config,containers,gateway,services}`), `.check-stock`, `.blocky`. These keep their nixpkgs-style `enable` options (spec: service modules keep their gate). `media` imports `tsnsrv`.

- [ ] **Step 1: Move and wrap**

```bash
git mv modules/_legacy/tsnsrv.nix modules/_legacy/check-stock.nix modules/_legacy/blocky.nix modules/
git mv modules/_legacy/media modules/media
python3 -I scripts/dendritic/dendritic.py checkpaths modules/tsnsrv.nix modules/check-stock.nix modules/blocky.nix modules/media/*.nix
for f in tsnsrv check-stock blocky; do
  python3 -I scripts/dendritic/dendritic.py wrap --root modules --into "flake.modules.nixos.$f" --key "modules/$f" "modules/$f.nix"
done
for f in config containers gateway services; do
  python3 -I scripts/dendritic/dendritic.py wrap --root modules --into flake.modules.nixos.media --key "modules/media/$f" "modules/media/$f.nix"
done
```

Fix any `DANGLING` first. `__utils.nix` is a helper and stays unwrapped.

`modules/media/services.nix` guards the lower layers by file path: Task 2 changed its `modules/media/` prefix to `modules/_legacy/media/`. Set it back to `modules/media/` here, or every host fails the `media.gateway.services`/`media.containers` assertion. (`checks.x86_64-linux.media-lower-layers-guarded` must still evaluate.)

- [ ] **Step 2: `media` imports `tsnsrv`**

In `modules/media/services.nix`, make the outer function take `config` (add it to the existing outer pattern, or create `{config, ...}:` if there is none), bind `features`, and add tsnsrv to the keyed wrapper's imports:

```nix
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  flake.modules.nixos.media = {
    key = "modules/media/services";
    imports = [
      features.tsnsrv
      (<the wrapped module, unchanged>)
    ];
  };
}
```

- [ ] **Step 3: Feature lists**

In `modules/flake/hosts.nix`, set `legacyFeatures`:

```nix
  legacyFeatures = {
    basestar = ["media" "tsnsrv"];
    galactica = ["check-stock" "media" "tsnsrv"];
    octopi = ["tsnsrv"];
    pegasus = ["media" "tsnsrv"];
    raider = ["tsnsrv"];
    raspi3 = ["tsnsrv"];
    # podman (still in _legacy) reads media.containers.
    router = ["media"];
  };
```

- [ ] **Step 4: Track, format, verify**

```bash
git add -A modules
just fmt
scripts/dendritic/verify.sh check
```

Expected: `MATCH`/accepted `LOOSE-ONLY` for all hosts, `MATCH flake outputs`. A host outside the lists failing on a `media.*` or `services.tsnsrv` option means a legacy module reads it. Add that host to the list only if the table shows it uses the feature. Otherwise find the reader and make it import the feature when it moves (record it in the commit message).

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(modules): tsnsrv, media, check-stock and blocky as importable features"
```

---

### Task 5: `podman`, `virtualization`, `netdata-client`, `development`, `forgejo-runner`

**Files:**
- Move: `_legacy/constellation/{podman,virtualization,netdata-client,development,forgejo-runner}.nix` → `modules/`
- Modify: `modules/flake/hosts.nix`; host setters; `hosts/galactica/services/vpn-exit-nodes.nix`, `hosts/raider/project-vms.nix` (conditional enables)

**Interfaces:**
- Produces: `flake.modules.nixos.{podman,virtualization,netdata-client,development,forgejo-runner}`, no `enable` options. `podman` imports `media`.

- [ ] **Step 1: Move and wrap**

```bash
for f in podman virtualization netdata-client development forgejo-runner; do
  git mv "modules/_legacy/constellation/$f.nix" "modules/$f.nix"
done
python3 -I scripts/dendritic/dendritic.py checkpaths modules/{podman,virtualization,netdata-client,development,forgejo-runner}.nix
for f in podman virtualization netdata-client development forgejo-runner; do
  python3 -I scripts/dendritic/dendritic.py wrap --root modules --into "flake.modules.nixos.$f" --key "modules/$f" "modules/$f.nix"
done
```

- [ ] **Step 2: Remove the enable switches**

In each file, delete `enable` from `options.constellation.<podman|virtualization|netdataClient|development|forgejo-runner>` and unwrap `lib.mkIf cfg.enable`. Sub-options (`development.docker`, …) stay.

In `modules/podman.nix`, add `media` to the keyed wrapper's imports exactly as Task 4 Step 2 did for tsnsrv (outer `{config, ...}:`, `features = config.flake.modules.nixos;`, `imports = [features.media (<module>)];`), with the comment `# reads media.containers to decide which images to watch`.

- [ ] **Step 3: Delete the setters**

Run: `grep -rnE "(podman|virtualization|netdataClient|development|forgejo-runner)\.enable\s*=" hosts modules`

Delete each `enable` line it prints (inside an attrset like `constellation.development = { enable = true; docker = false; };` delete only `enable = true;`). Two are conditional and simply go:
- `hosts/galactica/services/vpn-exit-nodes.nix`: `constellation.podman.enable = true;` inside the disabled module's `mkIf`. galactica imports podman anyway.
- `hosts/raider/project-vms.nix`: `constellation.virtualization.enable = true;`. raider imports virtualization anyway.

Expected afterwards: the grep prints nothing.

- [ ] **Step 4: Feature lists**

```nix
  legacyFeatures = {
    basestar = ["media" "netdata-client" "podman" "tsnsrv" "virtualization"];
    blackbird = ["development" "netdata-client" "virtualization"];
    galactica = ["check-stock" "development" "forgejo-runner" "media" "podman" "tsnsrv" "virtualization"];
    octopi = ["netdata-client" "tsnsrv" "virtualization"];
    pegasus = ["media" "netdata-client" "podman" "tsnsrv" "virtualization"];
    r2s = ["netdata-client" "virtualization"];
    raider = ["development" "media" "netdata-client" "tsnsrv" "virtualization"];
    raspi3 = ["netdata-client" "tsnsrv" "virtualization"];
    router = ["podman"];
  };
```

(router's `media` now comes through `podman`.)

- [ ] **Step 5: Track, format, verify, commit**

```bash
git add -A modules hosts
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(modules): podman, virtualization, netdata-client, development, forgejo-runner imported instead of enabled"
```

Expected before committing: `MATCH`/accepted `LOOSE-ONLY` for all hosts, `MATCH flake outputs`.

---

### Task 6: Backups

**Files:**
- Move: `_legacy/constellation/{backrest,backup-notify,backup-status,backup-summary}.nix` → `modules/backup/`
- Modify: `modules/flake/hosts.nix`; `hosts/galactica/backup/rustic.nix:288-289`; `hosts/galactica/backup/default.nix:9`

**Interfaces:**
- Produces: `flake.modules.nixos.{backrest,backup-notify,backup-status,backup-summary}`, no `enable`. `backrest` imports `backup-notify` and `backup-status`.

- [ ] **Step 1: Move and wrap**

```bash
mkdir -p modules/backup
git mv modules/_legacy/constellation/{backrest,backup-notify,backup-status,backup-summary}.nix modules/backup/
python3 -I scripts/dendritic/dendritic.py checkpaths modules/backup/*.nix
for f in backrest backup-notify backup-status backup-summary; do
  python3 -I scripts/dendritic/dendritic.py wrap --root modules --into "flake.modules.nixos.$f" --key "modules/backup/$f" "modules/backup/$f.nix"
done
```

- [ ] **Step 2: Remove enable switches and wire dependencies**

In each file, delete `enable` from `options.constellation.{backrest,backupNotify,backupStatus,backupSummary}` and unwrap `lib.mkIf cfg.enable`.

In `modules/backup/backrest.nix`: delete `constellation.backupNotify.enable = lib.mkDefault true;` and `constellation.backupStatus.enable = lib.mkDefault true;` (lines 495–496 before this task), and give the keyed wrapper `imports = [features.backup-notify features.backup-status (<module>)];` with the outer `{config, ...}: let features = config.flake.modules.nixos; in` binding.

In `hosts/galactica/backup/rustic.nix`: delete the same two `mkDefault true` lines (288–289). galactica gets both through `backrest`. In `hosts/galactica/backup/default.nix`: delete `constellation.backupSummary.enable = true;`.

Run: `grep -rnE "(backrest|backupNotify|backupStatus|backupSummary)\.enable\s*=|^\s*backrest\s*=\s*\{" hosts modules`
Then delete any remaining `enable = true;` inside a host's `constellation.backrest = { … }`. Expected afterwards: no `.enable` setter left.

- [ ] **Step 3: Feature lists**

Add `"backrest"` to basestar, galactica, pegasus, raider, and `"backup-summary"` to galactica, keeping each list sorted.

- [ ] **Step 4: Track, format, verify, commit**

```bash
git add -A modules hosts
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(modules): backup features imported instead of enabled"
```

---

### Task 7: Desktop and gaming

**Files:**
- Move: `_legacy/constellation/desktop.nix` → `modules/desktop/desktop.nix`; `_legacy/constellation/pantheon-dock/` → `modules/desktop/pantheon-dock/`; `_legacy/constellation/pantheon-gamemode.nix` → `modules/desktop/pantheon-gamemode.nix`; `_legacy/constellation/gaming.nix` → `modules/gaming.nix`
- Modify: `modules/flake/hosts.nix`; blackbird and raider setters; `tests/pantheon-dock-test.nix`, `tests/pantheon-gamemode-test.nix`

**Interfaces:**
- Produces: `flake.modules.nixos.{desktop,pantheon-dock,pantheon-gamemode,gaming}`. `desktop` imports `pantheon-dock` and `pantheon-gamemode`, whose own Pantheon/gamemode conditions stay.

- [ ] **Step 1: Move and wrap**

```bash
mkdir -p modules/desktop
git mv modules/_legacy/constellation/desktop.nix modules/_legacy/constellation/pantheon-gamemode.nix modules/desktop/
git mv modules/_legacy/constellation/pantheon-dock modules/desktop/pantheon-dock
git mv modules/_legacy/constellation/gaming.nix modules/gaming.nix
python3 -I scripts/dendritic/dendritic.py checkpaths modules/desktop/*.nix modules/desktop/pantheon-dock/default.nix modules/gaming.nix
python3 -I scripts/dendritic/dendritic.py wrap --root modules --into flake.modules.nixos.desktop --key modules/desktop/desktop modules/desktop/desktop.nix
python3 -I scripts/dendritic/dendritic.py wrap --root modules --into flake.modules.nixos.pantheon-dock --key modules/desktop/pantheon-dock/default modules/desktop/pantheon-dock/default.nix
python3 -I scripts/dendritic/dendritic.py wrap --root modules --into flake.modules.nixos.pantheon-gamemode --key modules/desktop/pantheon-gamemode modules/desktop/pantheon-gamemode.nix
python3 -I scripts/dendritic/dendritic.py wrap --root modules --into flake.modules.nixos.gaming --key modules/gaming modules/gaming.nix
```

`pantheon-gamemode.nix:17` references the indicator package by path. `checkpaths` flags it if it broke: it must point at `../../packages/wingpanel-indicator-gamemode/package.nix`. Confirm `find modules/desktop/pantheon-dock -name '*.nix'` lists only `default.nix`.

- [ ] **Step 2: Remove enable switches, wire dependencies**

`desktop.nix` and `gaming.nix`: delete the top-level `enable` option and unwrap the `cfg.enable` gate. Sub-option gates such as `desktop.variant` or default-true sub-features stay. `desktop.nix` gets `imports = [features.pantheon-dock features.pantheon-gamemode (<module>)];` with the outer `features` binding.

Run: `grep -rnE "(desktop|gaming)\.enable\s*=" hosts modules` and delete each setter (blackbird, raider; inside an attrset delete only `enable = true;`). Expected afterwards: no output.

- [ ] **Step 3: Tests take the module from the file**

`tests/pantheon-dock-test.nix`: replace the import entry `../modules/_legacy/constellation/pantheon-dock` with

```nix
      (import ../modules/desktop/pantheon-dock/default.nix).flake.modules.nixos.pantheon-dock
```

`tests/pantheon-gamemode-test.nix`: replace `../modules/_legacy/constellation/pantheon-gamemode.nix` with

```nix
      (import ../modules/desktop/pantheon-gamemode.nix).flake.modules.nixos.pantheon-gamemode
```

If `wrap` gave either file an outer function, it takes `self`/`inputs`. That would need the test to receive them; the pantheon files take neither, so a plain `import` works. Check with `head -3` on each.

- [ ] **Step 4: Feature lists**

Add `"desktop"` and `"gaming"` to blackbird and raider, keeping lists sorted.

- [ ] **Step 5: Track, format, verify, build the two tests, commit**

```bash
git add -A modules hosts tests
just fmt
scripts/dendritic/verify.sh check
nice nix build .#checks.x86_64-linux.pantheon-dock-test .#checks.x86_64-linux.pantheon-gamemode-test
git commit -m "refactor(modules): desktop, pantheon and gaming imported instead of enabled"
```

Expected: verify as before; both VM tests build and pass.

---

### Task 8: Remove haumea

`_legacy/` is now empty of modules.

**Files:**
- Delete: `modules/_legacy/`
- Modify: `modules/flake/lib.nix` (the haumea block), `flake.nix` (haumea input), `flake.lock`

- [ ] **Step 1: Confirm it is empty**

Run: `find modules/_legacy -type f`
Expected: no output. If anything is left, it is a module this plan missed: stop and add it to the right task's feature group first.

- [ ] **Step 2: Delete the loader**

`rmdir -p modules/_legacy` (or `rm -r` if empty dirs remain). `modules/base/common.nix` writes every flake input into `nix.registry`/`nix.nixPath` except those in its `removeAttrs` list (Task 2 added `import-tree` there). Removing the haumea input therefore drops its registry entry on every host: expect `DIFF` on all ten whose `explain` shows only the registry, `NIX_PATH` and `set-environment`/`etc-pam-environment` losing `haumea`. That is the intended change: accept it, say so in the commit message, then re-record the baseline (`verify.sh baseline <host>` for each host, one per command) so later tasks compare against the new state. In `modules/flake/lib.nix`, delete the whole `# Load all modules from the modules directory` block from `baseModules`. In `flake.nix`, delete the two `haumea` lines. Run `nix flake lock` and confirm the diff only removes `haumea`.

- [ ] **Step 3: Verify, commit**

```bash
git add -A modules flake.nix flake.lock
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(modules): drop haumea, every shared module is a feature"
```

---

## Host conversion (Tasks 9–18)

Each host task converts one host. Within each task, run its steps in order. The commands are written out in full per host.

What every host conversion does:

1. `dendritic.py hide hosts/<h>`: prefix helpers, tests and dead files with `_`.
2. `git mv hosts/<h> modules/hosts/<h>`, then `fixpaths` for paths that left the tree.
3. `wrap` every remaining `.nix` file into `configurations.nixos.<h>.module`. This deletes files that only imported siblings.
4. Write `modules/hosts/<h>.nix`, the declaration: metadata plus `module.imports` (disko if present, then the features from `legacyFeatures.<h>`).
5. Delete `<h>` from `legacy` and `legacyFeatures` in `modules/flake/hosts.nix`.
6. Repoint any outside reference (checks, tests, justfile) to the new path.
7. Format, verify, check, commit.

Two things to watch for, from the merge-order note in the split plan: imported definitions merge first, in reverse import order, and the importing module's own definitions come last. import-tree orders the host's files by path, which differs from the old `imports` lists, so list-valued options can reorder. `verify.sh` reports that as `LOOSE-ONLY`. Read `explain`, and pin any order that matters with `lib.mkBefore`/`lib.mkOrder` in the file that owns the entry.

---

### Task 9: octopi

**Files:** Move `hosts/octopi/` → `modules/hosts/octopi/`; create `modules/hosts/octopi.nix`; modify `modules/flake/hosts.nix`.

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/octopi
mkdir -p modules/hosts
git mv hosts/octopi modules/hosts/octopi
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/octopi modules/hosts/octopi
find modules/hosts/octopi -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/octopi --into configurations.nixos.octopi.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/octopi -name '*.nix')
```

Expected: `hide` prints nothing to hide; `wrap` no `SKIPPED`; `checkpaths` no `DANGLING`.

- [ ] **Step 2: Declaration**

`modules/hosts/octopi.nix`:

```nix
# octopi: OctoPrint on a Raspberry Pi. Configuration in ./octopi/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.octopi = {
    homeManager = false;
    module.imports = [
      features.netdata-client
      features.tsnsrv
      features.virtualization
    ];
  };
}
```

In `modules/flake/hosts.nix`, delete `octopi` from `legacy` and from `legacyFeatures`.

- [ ] **Step 3: Track, format, verify, commit**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(octopi): declare the host in modules/hosts"
```

---

### Task 10: raspi3

Same steps as octopi, written out:

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/raspi3
git mv hosts/raspi3 modules/hosts/raspi3
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/raspi3 modules/hosts/raspi3
find modules/hosts/raspi3 -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/raspi3 --into configurations.nixos.raspi3.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/raspi3 -name '*.nix')
```

- [ ] **Step 2: Declaration** — `modules/hosts/raspi3.nix`:

```nix
# raspi3: Raspberry Pi 3. Configuration in ./raspi3/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.raspi3 = {
    homeManager = false;
    module.imports = [
      features.netdata-client
      features.tsnsrv
      features.virtualization
    ];
  };
}
```

Delete `raspi3` from `legacy` and `legacyFeatures`.

- [ ] **Step 3: Track, format, verify, commit**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(raspi3): declare the host in modules/hosts"
```

---

### Task 11: r2s

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/r2s
git mv hosts/r2s modules/hosts/r2s
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/r2s modules/hosts/r2s
find modules/hosts/r2s -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/r2s --into configurations.nixos.r2s.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/r2s -name '*.nix')
```

Expected: `hide` moves `helpers.nix` → `_helpers.nix` and `networking.nix` → `_networking.nix`, and rewrites `configuration.nix`'s `(import ./networking.nix {…})` to `./_networking.nix`. Check with `grep -rn "helpers.nix\|networking.nix" modules/hosts/r2s`: every hit uses the `_` name.

- [ ] **Step 2: Declaration** — `modules/hosts/r2s.nix`:

```nix
# r2s: NanoPi R2S router board. Configuration in ./r2s/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.r2s = {
    homeManager = false;
    module.imports = [
      features.netdata-client
      features.virtualization
    ];
  };
}
```

Delete `r2s` from `legacy` and `legacyFeatures`.

- [ ] **Step 3: Track, format, verify, commit**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(r2s): declare the host in modules/hosts"
```

---

### Task 12: cylon-link

**Also modifies:** `modules/flake/checks.nix` (`cylon-link-boot`, `cylon-link-config`), `justfile:525` (`flash.sh` path).

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/cylon-link
git mv hosts/cylon-link modules/hosts/cylon-link
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/cylon-link modules/hosts/cylon-link
find modules/hosts/cylon-link -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/cylon-link --into configurations.nixos.cylon-link.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/cylon-link -name '*.nix')
```

Expected: `hide` moves `config-test.nix`, `boot/package.nix`, `boot/test.nix` to `_` names and rewrites `boot/default.nix`'s and `boot/_test.nix`'s `./package.nix` to `./_package.nix`. `checkpaths` reports one `DANGLING ./files/etc/ssh` in `image.nix`. That is a shell string, not a Nix path, so ignore it.

- [ ] **Step 2: Outside references**

In `modules/flake/checks.nix`:
- `import ../../hosts/cylon-link/boot/test.nix` → `import ../hosts/cylon-link/boot/_test.nix`
- `import ../../hosts/cylon-link/config-test.nix` → `import ../hosts/cylon-link/_config-test.nix`

In `justfile` (the `flash-cylon-link` recipe): `bash hosts/cylon-link/flash.sh` → `bash modules/hosts/cylon-link/flash.sh`.

Run: `grep -rn "hosts/cylon-link" --include=*.nix --include=justfile --include=*.just --include=*.sh . | grep -v '^./docs\|^./modules/hosts/cylon-link'` and fix anything still pointing at the old path (comments too).

- [ ] **Step 3: Declaration** — `modules/hosts/cylon-link.nix`:

```nix
# cylon-link: Valve Steam Link, cross-compiled on raider. Configuration in ./cylon-link/.
{
  configurations.nixos.cylon-link = {
    homeManager = false;
    # CI never builds this host. It is cross-compiled for armv7l and its kernel
    # alone outlasts the build job's 120-minute timeout on a GitHub runner.
    # raider builds it in `just deploy` phase 1 instead.
    ci = false;
    module = {};
  };
}
```

(`module = {};` gives the option a definition; the host's own files add the rest.) Delete `cylon-link` from `legacy` and `legacyFeatures`.

- [ ] **Step 4: Track, format, verify, commit**

```bash
git add -A hosts modules justfile
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(cylon-link): declare the host in modules/hosts"
```

---

### Task 13: router

**Also modifies:** `tests/router-test.nix` (imports of router files).

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/router
git mv hosts/router modules/hosts/router
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/router modules/hosts/router
find modules/hosts/router -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/router --into configurations.nixos.router.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/router -name '*.nix')
```

Expected: `hide` moves `hardware-offload.nix`, `loop-protection.nix`, `performance-tuning.nix`, `xdp-firewall.nix`, `services/dnsmasq-dhcp.nix` to `_` names and `dashboards/` → `_dashboards/`, and rewrites `services/monitoring.nix`'s `import ../dashboards` to `../_dashboards`. `services.nix` survives `wrap` because it still imports `../../../packages/network-metrics-exporter/module.nix`.

- [ ] **Step 2: The router test takes modules out of the host files**

In `tests/router-test.nix`, replace the three `"${self}/hosts/router/…"` import entries with the result of this helper (add it in the test's top-level `let`):

```nix
  # Router host files are flake-parts modules (modules/hosts/router/); take the
  # NixOS module each one defines.
  routerModule = file: let
    m = import "${self}/modules/hosts/router/${file}";
  in
    (
      if builtins.isFunction m
      then m {inherit self inputs;}
      else m
    ).configurations.nixos.router.module;
  routerServices =
    map (f: routerModule "services/${f}")
    (builtins.filter (f: builtins.match "[^_].*\\.nix" f != null)
      (builtins.attrNames (builtins.readDir "${self}/modules/hosts/router/services")));
```

and in the router node's `imports`:

```nix
        (routerModule "network.nix")
        (routerModule "services.nix")
        (routerModule "alerting.nix")
      ]
      ++ routerServices
      ++ [
```

(Keep the remaining entries: `inputs.sops-nix.nixosModules.sops` and the base `caddy-security` import from Task 3.) Update the comment above it that names `hosts/router/services/caddy.nix`. `tests/router-ipv6-test.nix` is not wired into any check; leave it.

- [ ] **Step 3: Declaration** — `modules/hosts/router.nix`:

```nix
# router: the home router. Configuration in ./router/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.router.module.imports = [
    inputs.disko.nixosModules.disko
    features.podman
  ];
}
```

Delete `router` from `legacy` and `legacyFeatures`.

- [ ] **Step 4: Track, format, verify, run the router test, commit**

```bash
git add -A hosts modules tests
just fmt
scripts/dendritic/verify.sh check
nice nix build .#checks.x86_64-linux.router-test
git commit -m "refactor(router): declare the host in modules/hosts; hide its unused modules"
```

---

### Task 14: pegasus

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/pegasus
git mv hosts/pegasus modules/hosts/pegasus
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/pegasus modules/hosts/pegasus
find modules/hosts/pegasus -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/pegasus --into configurations.nixos.pegasus.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/pegasus -name '*.nix')
```

Expected: nothing hidden; `services/default.nix` and `backup/default.nix` are deleted by `wrap` (they only imported siblings); the three `../../../secrets/sops/pegasus.yaml` paths become `../../../../secrets/…` via `fixpaths`.

- [ ] **Step 2: Declaration** — `modules/hosts/pegasus.nix`:

```nix
# pegasus: secondary server. Configuration in ./pegasus/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.pegasus.module.imports = [
    inputs.disko.nixosModules.disko
    features.backrest
    features.media
    features.netdata-client
    features.podman
    features.tsnsrv
    features.virtualization
  ];
}
```

Delete `pegasus` from `legacy` and `legacyFeatures`.

- [ ] **Step 3: Track, format, verify, commit**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(pegasus): declare the host in modules/hosts"
```

---

### Task 15: basestar

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/basestar
git mv hosts/basestar modules/hosts/basestar
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/basestar modules/hosts/basestar
find modules/hosts/basestar -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/basestar --into configurations.nixos.basestar.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/basestar -name '*.nix')
```

Expected: `hide` moves `k8s/lib.nix` → `k8s/_lib.nix` and rewrites `k8s/default.nix`'s `import ./lib.nix` (including the commented example on line 18). `services/default.nix` and `sites/default.nix` are deleted by `wrap`.

Update the comments that name moved paths: `k8s/_lib.nix:1` and `:4`, `k8s/default.nix:9,31` and `k3s.nix:489,493` refer to `hosts/basestar/...`; change them to `modules/hosts/basestar/...` (and `lib.nix` → `_lib.nix`). Run `grep -rn "hosts/basestar" modules/hosts/basestar` and fix each.

- [ ] **Step 2: Declaration** — `modules/hosts/basestar.nix`:

```nix
# basestar: public-facing server on Oracle Cloud, *.arsfeld.dev and the k3s
# cluster. Configuration in ./basestar/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.basestar = {
    tier = "tier1";
    module.imports = [
      features.backrest
      features.media
      features.netdata-client
      features.podman
      features.tsnsrv
      features.virtualization
    ];
  };
}
```

Delete `basestar` from `legacy` and `legacyFeatures`.

- [ ] **Step 3: Track, format, verify, commit**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(basestar): declare the host in modules/hosts"
```

---

### Task 16: blackbird (with the split)

The split follows `docs/superpowers/specs/2026-10-31-split-host-configurations-design.md` and the per-file content of `docs/superpowers/plans/2026-10-31-split-host-configurations.md` Task 1 (Steps 2–8: which lines of `configuration.nix` go into `dgpu-power.nix`, `nvidia.nix`, `asus.nix`, `audio.nix`, `fingerprint.nix`, `power.nix`). Three differences from that plan:
- the new files are written in wrapped form (template below) and are added to no `imports` list;
- `dgpu-power.nix` is a `callPackage` function, so it is `_dgpu-power.nix`, and both call sites use `pkgs.callPackage ./_dgpu-power.nix {nvidia = config.hardware.nvidia.package;}`;
- the proof is `verify.sh`, not drvPath equality. That plan's rule "never split a list-valued option across files" still holds.

**Also modifies:** `modules/flake/checks.nix` only if it references blackbird paths (it does not today; `blackbird-audio-control-test` uses `self.nixosConfigurations.blackbird`).

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/blackbird
git mv hosts/blackbird modules/hosts/blackbird
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/blackbird modules/hosts/blackbird
find modules/hosts/blackbird -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/blackbird --into configurations.nixos.blackbird.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/blackbird -name '*.nix')
```

- [ ] **Step 2: Declaration** — `modules/hosts/blackbird.nix`:

```nix
# blackbird: ASUS ROG Zephyrus G14 laptop. Configuration in ./blackbird/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.blackbird.module.imports = [
    inputs.disko.nixosModules.disko
    features.desktop
    features.development
    features.gaming
    features.netdata-client
    features.virtualization
  ];
}
```

Delete `blackbird` from `legacy` and `legacyFeatures`.

- [ ] **Step 3: Verify and commit the move before splitting**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(blackbird): declare the host in modules/hosts"
```

- [ ] **Step 4: Split `configuration.nix`**

Each new file has this shape (the argument pattern lists what its body uses):

```nix
# <one-line purpose, as in the split spec's table>
{
  configurations.nixos.blackbird.module = {
    config,
    lib,
    pkgs,
    ...
  }: {
    <lines moved verbatim from configuration.nix>
  };
}
```

Move the code per the split plan's Task 1 Steps 2–8, verbatim with its comments, into `modules/hosts/blackbird/{nvidia,asus,audio,fingerprint,power}.nix` and `_dgpu-power.nix`. If a moved block used a `let` binding from `configuration.nix`, move the binding too. If two files need it, use the duplication the split spec chose (`gsettingsOverrides` lives in `power.nix`).

- [ ] **Step 5: Verify, test, commit**

```bash
git add -A modules
just fmt
scripts/dendritic/verify.sh check blackbird
nice nix build .#checks.x86_64-linux.blackbird-audio-control-test
git commit -m "refactor(blackbird): split configuration.nix by concern"
```

Expected: `MATCH` (or accepted `LOOSE-ONLY`) for blackbird. Compare the moved text with the split plan's Step 9 check: concatenated, sorted, non-blank lines before and after must be equal apart from the wrapper lines.

---

### Task 17: raider (with the split)

Split per `docs/superpowers/plans/2026-10-31-split-host-configurations.md` Task 2 (`stash.nix`, `niks3.nix`, `backup.nix`, `nix-builds.nix`, `no-suspend.nix`), with the same three differences as Task 16. `niks3.nix` keeps `inputs.niks3.nixosModules.niks3-auto-upload` in its own `imports`, and `inputs` comes from the file's outer function (`{inputs, ...}: { configurations.nixos.raider.module = …; }`).

**Also modifies:** `modules/flake/checks.nix` (`fan-control` path), `hosts/raider/configuration.nix` comment references in `CLAUDE.md` are handled in Task 19.

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/raider
git mv hosts/raider modules/hosts/raider
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/raider modules/hosts/raider
find modules/hosts/raider -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/raider --into configurations.nixos.raider.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/raider -name '*.nix')
```

Expected: `hide` moves `appimage.nix` → `_appimage.nix` (nothing imports it).

In `modules/flake/checks.nix`: `${../../hosts/raider/fan-control}` → `${../hosts/raider/fan-control}`.

- [ ] **Step 2: Declaration** — `modules/hosts/raider.nix`:

```nix
# raider: desktop workstation and the deploy driver. Configuration in ./raider/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.raider = {
    nixpkgs = "unstable";
    tier = "tier1";
    module.imports = [
      inputs.disko.nixosModules.disko
      features.backrest
      features.desktop
      features.development
      features.gaming
      features.media
      features.netdata-client
      features.tsnsrv
      features.virtualization
    ];
  };
}
```

Delete `raider` from `legacy` and `legacyFeatures`.

- [ ] **Step 3: Verify and commit the move**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
git commit -m "refactor(raider): declare the host in modules/hosts"
```

- [ ] **Step 4: Split `configuration.nix`**

Same wrapped-file shape as Task 16 Step 4, with `configurations.nixos.raider.module`. Move per the split plan's Task 2 into `modules/hosts/raider/{stash,niks3,backup,nix-builds,no-suspend}.nix`.

- [ ] **Step 5: Verify, commit**

```bash
git add -A modules
just fmt
scripts/dendritic/verify.sh check raider
git commit -m "refactor(raider): split configuration.nix by concern"
```

---

### Task 18: galactica

**Also modifies:** `modules/flake/checks.nix` (`immich-pixel-sync`, `home-assistant-heating` paths).

- [ ] **Step 1: Hide, move, wrap**

```bash
python3 -I scripts/dendritic/dendritic.py hide hosts/galactica
git mv hosts/galactica modules/hosts/galactica
python3 -I scripts/dendritic/dendritic.py fixpaths hosts/galactica modules/hosts/galactica
find modules/hosts/galactica -name '*.nix' ! -path '*/_*' -print0 \
  | xargs -0 python3 -I scripts/dendritic/dendritic.py wrap --root modules/hosts/galactica --into configurations.nixos.galactica.module
python3 -I scripts/dendritic/dendritic.py checkpaths $(find modules/hosts/galactica -name '*.nix')
```

Expected: `hide` moves `services/metrics.nix`, `services/timemachine.nix`, `services/home-assistant-heating/templates.nix`, `services/home-assistant-heating/zones.nix` to `_` names and rewrites `home-assistant-heating/default.nix`'s `import ./templates.nix` / `./zones.nix`. `wrap` deletes `services/default.nix` and `scripts/default.nix` (siblings-only). `backup/default.nix` keeps its body (it set `backupSummary.enable` before Task 6; check what is left. If it is now siblings-only, `wrap` deleted it).

In `modules/flake/checks.nix`:
- `${../../hosts/galactica/services/immich-pixel-sync}` → `${../hosts/galactica/services/immich-pixel-sync}`
- `${../../hosts/galactica/services/home-assistant-heating}` → `${../hosts/galactica/services/home-assistant-heating}`

- [ ] **Step 2: Declaration** — `modules/hosts/galactica.nix`:

```nix
# galactica: main server. Media services, databases, backups; *.arsfeld.one.
# Configuration in ./galactica/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.galactica = {
    tier = "tier1";
    module.imports = [
      inputs.disko.nixosModules.disko
      features.backrest
      features.backup-summary
      features.check-stock
      features.development
      features.forgejo-runner
      features.media
      features.podman
      features.tsnsrv
      features.virtualization
    ];
  };
}
```

Delete `galactica` from `legacy` and `legacyFeatures`. Both attrsets are now `{}`.

- [ ] **Step 3: Verify, run the python checks, commit**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
nice nix build .#checks.x86_64-linux.immich-pixel-sync-test .#checks.x86_64-linux.home-assistant-heating-test
git commit -m "refactor(galactica): declare the host in modules/hosts"
```

(If a check attribute name differs, read it from `nix eval .#checks.x86_64-linux --apply builtins.attrNames`.)

---

### Task 19: Remove the scaffolding, export `nixosModules`, rewrite the docs

**Files:**
- Modify: `modules/flake/hosts.nix` (delete `legacy`, `legacyFeatures`, `legacyHosts` and the legacy `configurations.nixos` definition); `modules/flake/lib.nix` (`specialArgs`)
- Create: `modules/flake/nixos-modules.nix`
- Delete: `hosts/` (now empty), `scripts/dendritic/`
- Modify: `CLAUDE.md`, `README.md`, `modules/gaming.nix:821` (comment naming `unstableHosts`), superseded/folded specs and plans (header note)

- [ ] **Step 1: Delete the legacy feed**

`hosts/` must be empty: `find hosts -type f` prints nothing; `rmdir hosts`. In `modules/flake/hosts.nix` delete `legacy`, `legacyFeatures`, `legacyHosts`, their comments, and the `configurations.nixos = lib.mapAttrs … legacyHosts;` definition, plus the `features` binding if now unused.

- [ ] **Step 2: Drop `specialArgs`**

In `modules/flake/lib.nix`, delete `specialArgs = {inherit self inputs;};` from `mkLinuxSystem`. `home-manager.extraSpecialArgs` stays.

Run `scripts/dendritic/verify.sh check <host>` for each host, one per command (it never evaluates cylon-link's toplevel). A failure `called without required argument 'inputs'` (or `'self'`) names a module that still takes it from its argument pattern. It is one `wrap` reported `SKIPPED` for, or a `packages/*/module.nix`. Move the name to that file's outer function by hand (as `wrap` does) and re-run.

- [ ] **Step 3: Export**

`modules/flake/nixos-modules.nix`:

```nix
{config, ...}: {
  # Published for discovery (`nix flake show`). These modules assume this
  # flake's `base` module and overlays; they are not built to work in another
  # flake.
  flake.nixosModules = config.flake.modules.nixos;
}
```

Run: `nix eval --json .#nixosModules --apply builtins.attrNames`
Expected: `["backrest","backup-notify","backup-status","backup-summary","base","blocky","check-stock","desktop","development","forgejo-runner","gaming","media","netdata-client","pantheon-dock","pantheon-gamemode","podman","tsnsrv","virtualization"]`

- [ ] **Step 4: Final verification, then delete the tooling**

```bash
git add -A hosts modules
just fmt
scripts/dendritic/verify.sh check
grep -rnE "with lib;" --include=*.nix modules packages | grep -v '/_' | grep -vE '^packages/(telequebec-archiver|natpmp-server|network-metrics-exporter)/'
grep -rnE "haumea|specialArgs|_legacy|flake-modules" --include=*.nix --include=justfile --include=*.just --include=*.yml . | grep -v '^./docs'
```

Expected: verify all `MATCH`/accepted `LOOSE-ONLY`; both greps print nothing (`extraSpecialArgs`, which stays for home-manager, does not match the case-sensitive `specialArgs`).

Then `git rm -r scripts/dendritic`.

- [ ] **Step 5: Docs**

`CLAUDE.md`: rewrite these sections to the new structure, keeping their voice and every fact that still holds:
- "Flake Structure": `flake.nix` hands `modules/` to import-tree; list `modules/flake/{lib,hosts,deploy,checks,dev,images,infra,systems,nixos-modules}.nix`; describe `configurations.nixos.<name>` and its five keys.
- "Module Auto-Discovery": replace the haumea description with: every `.nix` under `modules/` is a flake-parts module except paths containing `/_`; shared features are `flake.modules.nixos.<feature>`, turned on by importing them in the host's declaration; every feature carries a `key`; `base` is added to every host. Keep the "code only one host uses lives with that host" rule, with the paths now `modules/hosts/<host>/`, and state that a host file is a flake-parts module defining `configurations.nixos.<host>.module`.
- "Host Tiers": tiers come from each host's `tier` in `modules/hosts/<name>.nix`; `ciMatrix` excludes hosts with `ci = false`.
- "Constellation Modules": the table becomes the feature list with paths, and "enable" wording becomes "import".
- "Adding New Services" and "Directory Structure": `hosts/` → `modules/hosts/`; a new service file is just a new file in the host's directory (no `imports` edit).
- cylon-link section: `hosts/cylon-link/…` → `modules/hosts/cylon-link/…`; `ciExcludedHosts in flake-modules/hosts.nix` → `ci = false in modules/hosts/cylon-link.nix`.
- Every other `hosts/<name>/`, `flake-modules/` or `modules/constellation/` path in CLAUDE.md: repoint (`grep -n "hosts/\|flake-modules\|modules/constellation\|modules/media\|haumea" CLAUDE.md`).

`README.md`: same repointing (`grep -n "hosts/\|flake-modules\|modules/constellation" README.md`).

`modules/gaming.nix` near line 821: the comment naming `unstableHosts` → "hosts with `nixpkgs = \"unstable\"`".

At the top of `docs/superpowers/specs/2026-10-31-host-metadata-design.md` and `docs/superpowers/plans/2026-10-31-host-metadata.md` add: `> Superseded by 2026-10-31-dendritic-restructure-design.md; never built.` At the top of `docs/superpowers/specs/2026-10-31-split-host-configurations-design.md` and its plan add: `> Carried out as part of the dendritic restructure (Tasks 16–17 of 2026-10-31-dendritic-restructure.md).`

- [ ] **Step 6: Commit and push**

```bash
git add -A
git commit -m "refactor(modules): export nixosModules, drop specialArgs and the legacy host feed"
git push origin master
```

Watch `build.yml` and `checks.yml` on the push. Both must go green; `checks.yml` runs the VM tests this plan only evaluated.
