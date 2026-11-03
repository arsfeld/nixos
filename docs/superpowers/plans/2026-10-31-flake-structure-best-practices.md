# Flake Structure Best-Practice Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace six private `import inputs.nixpkgs-unstable` instances with one `pkgs.unstable` overlay, and load `packages/` with `lib.packagesFromDirectoryRecursive` instead of haumea — without changing any host's system closure.

**Architecture:** Both changes live in `flake-modules/lib.nix` (the shared overlay list and `loadPackages`), with call sites updated to match. Correctness is proven by recording the affected hosts' toplevel `drvPath` before any edit and asserting it is byte-identical after each task.

**Tech Stack:** Nix flakes, flake-parts, nixpkgs `lib.filesystem.packagesFromDirectoryRecursive`, haumea (kept for `modules/` only).

Spec: `docs/superpowers/specs/2026-10-31-flake-structure-best-practices-design.md`

## Global Constraints

- The toplevel `drvPath` of the five affected hosts — basestar, blackbird, galactica, raider, router — must be identical before and after each task. A difference is investigated and explained before committing.
- **Never evaluate hosts in parallel.** Concurrent full NixOS evaluations exhausted raider's RAM and took the machine down. `/tmp/flake-structure/drvs.sh` evaluates one host at a time under `nice`; run it in the background and wait, never alongside another evaluation.
- No `import inputs.nixpkgs*` may remain under `hosts/`, `modules/` or `home/`.
- `pkgs.unstable` gets no overlays; it inherits the host's `config`.
- haumea stays as a flake input; it still loads `modules/`.
- Commit straight to master (no branches, no worktrees). Conventional commits; never mention Claude.
- New/renamed files must be `git add`ed (or `git mv`ed) before `nix eval`/`nix build` — flakes only see tracked files.
- Run `just fmt` before each commit.

---

### Task 1: Record the baseline drvPaths

**Files:** none modified. Writes `/tmp/flake-structure/before/<host>` (outside the repo).

**Interfaces:**
- Produces: `/tmp/flake-structure/before/<host>` — one file per affected host containing its toplevel drvPath; and the script `/tmp/flake-structure/drvs.sh <dir>` used by Tasks 2 and 3.

- [ ] **Step 1: Write the snapshot script**

```bash
mkdir -p /tmp/flake-structure
cat > /tmp/flake-structure/drvs.sh <<'EOF'
#!/usr/bin/env bash
# Usage: drvs.sh <outdir>  — writes one toplevel drvPath per host into <outdir>.
set -euo pipefail
out=$1
mkdir -p "$out"
cd /home/arosenfeld/Code/nixos
for h in $(nix eval --json .#hosts | jq -r '.[]'); do
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" > "$out/$h"
  echo "$h $(cat "$out/$h")"
done
EOF
chmod +x /tmp/flake-structure/drvs.sh
```

- [ ] **Step 2: Run it on a clean master**

Run: `git -C /home/arosenfeld/Code/nixos status --short && /tmp/flake-structure/drvs.sh /tmp/flake-structure/before`
Expected: empty `git status`, then five lines `<host> /nix/store/…-nixos-system-<host>-….drv` (basestar, blackbird, galactica, raider, router). Takes several minutes per host. If any host fails to evaluate, stop — the baseline must be complete.

(Executed by the controller on 2026-10-31 at fc577e9b; the script below was replaced by the sequential version described in Global Constraints.)

---

### Task 2: One shared `pkgs.unstable`

**Files:**
- Modify: `flake-modules/lib.nix` (the `overlays` list, ~lines 20-31)
- Modify: `hosts/galactica/configuration.nix:1-15`
- Modify: `hosts/galactica/services/immich.nix:1-14, 28`
- Modify: `hosts/galactica/backup/rustic.nix:40-53, 261-264`
- Modify: `modules/constellation/backrest.nix:26, 29, 38-40, 435-436`
- Modify: `modules/constellation/desktop.nix:11, 122-128, 177, 180, 193, 498`
- Modify: `home/home.nix:112-115, 681`
- Modify: `CLAUDE.md` (Architecture Overview → after "Module Auto-Discovery")

**Interfaces:**
- Consumes: `/tmp/flake-structure/drvs.sh`, `/tmp/flake-structure/before/*` from Task 1.
- Produces: `pkgs.unstable` — a nixpkgs-unstable package set for the host's platform, available in every NixOS module, in Home Manager (via `useGlobalPkgs`), and in the dev shell's `pkgs`.

- [ ] **Step 1: Write the failing checks**

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "import inputs.nixpkgs" hosts modules home
nix eval --raw .#nixosConfigurations.galactica.pkgs.unstable.rustic.name
```

- [ ] **Step 2: Run them to verify they fail**

Expected: `grep` prints six matches (galactica configuration/immich/rustic, desktop, backrest, home.nix); `nix eval` fails with `attribute 'unstable' missing`.

- [ ] **Step 3: Add the overlay in `flake-modules/lib.nix`**

In the `overlays = [ … ];` list, insert directly before the `# Load packages from ./packages directory using haumea` line:

```nix
      # nixpkgs-unstable as `pkgs.unstable`, one instance per package set.
      # It inherits the host's nixpkgs config (allowUnfree, …) and no overlays:
      # what we take from it is plain upstream packages, and our overlays
      # target stable. Never `import inputs.nixpkgs*` inside a module instead.
      (final: prev: {
        unstable = import inputs.nixpkgs-unstable {
          inherit (final.stdenv.hostPlatform) system;
          inherit (final) config;
        };
      })
```

- [ ] **Step 4: Update `hosts/galactica/configuration.nix`**

`pkgs-unstable` is bound but never used here. Replace lines 1-15:

```nix
{
  config,
  lib,
  pkgs,
  self,
  inputs,
  ...
}:
with lib; let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in {
```

with:

```nix
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
with lib; {
```

Then run `grep -n "inputs" hosts/galactica/configuration.nix`; expected: no output. (If `self` turns out unused too, leave it — out of scope.)

- [ ] **Step 5: Update `hosts/galactica/services/immich.nix`**

Remove the `inputs,` argument (line 5) and the binding (lines 9-13):

```nix
  # Use unstable for Immich 2.0
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
```

Keep the comment's intent on the use site — line 28 becomes:

```nix
    package = pkgs.unstable.immich; # Use Immich 2.0.1 from unstable
```

Run `grep -n "inputs\|pkgs-unstable" hosts/galactica/services/immich.nix`; expected: no output.

- [ ] **Step 6: Update `hosts/galactica/backup/rustic.nix`**

Remove the `inputs,` argument (line 44) and the binding (lines 50-52 plus the blank line after):

```nix
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };

```

Change the option (lines 261-264) to:

```nix
      default = pkgs.unstable.rustic;
      description = ''
        rustic package. Defaults to pkgs.unstable: stable is 0.11.2, and the
        cold-storage design was verified against 0.11.3.
      '';
```

Run `grep -n "inputs\|pkgs-unstable" hosts/galactica/backup/rustic.nix`; expected: no output.

- [ ] **Step 7: Update `modules/constellation/backrest.nix`**

- Line 26 comment: `#   - Uses pkgs-unstable.backrest …` → `#   - Uses pkgs.unstable.backrest to track upstream releases faster.`
- Remove the `inputs,` argument (line 29).
- Remove the binding (lines 38-40 plus the blank line after):

```nix
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
  };

```

- Lines 435-436 become:

```nix
      default = pkgs.unstable.backrest;
      description = "Backrest package (defaults to pkgs.unstable for faster upstream tracking).";
```

Run `grep -n "inputs\|pkgs-unstable" modules/constellation/backrest.nix`; expected: no output.

- [ ] **Step 8: Update `modules/constellation/desktop.nix`**

Remove the `inputs,` argument (line 11). Replace lines 122-128:

```nix
  config = lib.mkIf cfg.enable (let
    pkgs-unstable = import inputs.nixpkgs-unstable {
      system = pkgs.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  in
    lib.mkMerge [
```

with:

```nix
  config = lib.mkIf cfg.enable (lib.mkMerge [
```

The file's closing `    ]);` / `}` stays exactly as it is — it already closes `(… lib.mkMerge [ … ])`; only the `let … in` wrapper goes (`just fmt` reindents the body). Then:

```bash
sed -i 's/pkgs-unstable\./pkgs.unstable./g' modules/constellation/desktop.nix
grep -n "inputs\|pkgs-unstable" modules/constellation/desktop.nix
```

Expected: no output. The four uses are now `pkgs.unstable.zed-editor`, `(lib.hiPrio pkgs.unstable.ghostty)`, `pkgs.unstable.multiviewer-for-f1`, `pkgs.unstable.gnomeExtensions.monitorcontrol-brightness-and-volume`.

- [ ] **Step 9: Update `home/home.nix`**

Keep the `inputs` argument (line 77 uses `inputs.llm-agents`). Remove lines 112-115 plus the blank line after:

```nix
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

```

Line 681 becomes `    package = pkgs.unstable.zoxide;`. Run `grep -n "pkgs-unstable" home/home.nix`; expected: no output.

- [ ] **Step 10: Document the rule in `CLAUDE.md`**

Directly after the "### Module Auto-Discovery" section (before "### Constellation Modules"), add:

```markdown
### Packages from nixpkgs-unstable

Take them from `pkgs.unstable` — an overlay in `flake-modules/lib.nix` that
instantiates nixpkgs-unstable once per package set, inheriting the host's
nixpkgs config. Never `import inputs.nixpkgs*` inside a module, host file or
Home Manager config: each such import is another full nixpkgs evaluation per
host, carries its own idea of `allowUnfree`, and never sees our overlays.
```

- [ ] **Step 11: Format and run the checks to verify they pass**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
grep -rn "import inputs.nixpkgs" hosts modules home
nix eval --raw .#nixosConfigurations.galactica.pkgs.unstable.rustic.name
```

Expected: `grep` prints nothing; `nix eval` prints `rustic-0.11.3` or newer.

- [ ] **Step 12: Verify no closure changed**

```bash
/tmp/flake-structure/drvs.sh /tmp/flake-structure/task2
diff -r /tmp/flake-structure/before /tmp/flake-structure/task2 && echo IDENTICAL
```

Expected: `IDENTICAL`. If a host differs: `nix-diff "$(cat /tmp/flake-structure/before/<h>)" "$(cat /tmp/flake-structure/task2/<h>)"` (`nix run nixpkgs#nix-diff -- …`) and explain the difference before going on. If evaluation fails inside the overlay because stable's evaluated `config` is rejected by unstable's config module, replace `inherit (final) config;` with `config.allowUnfree = final.config.allowUnfree or false;`, update the overlay comment to say so, and re-run Steps 11-12.

- [ ] **Step 13: Commit**

```bash
git add flake-modules/lib.nix hosts/galactica/configuration.nix hosts/galactica/services/immich.nix \
  hosts/galactica/backup/rustic.nix modules/constellation/backrest.nix modules/constellation/desktop.nix \
  home/home.nix CLAUDE.md
git commit -m "refactor(modules): provide nixpkgs-unstable once as pkgs.unstable"
```

---

### Task 3: Load `packages/` with `packagesFromDirectoryRecursive`

**Files:**
- Rename: `packages/<name>/default.nix` → `packages/<name>/package.nix` (all 18)
- Modify: `flake-modules/lib.nix` (`loadPackages`, ~lines 8-19; overlay comment ~line 29)
- Modify: `flake-modules/dev.nix:140-146`
- Modify: `modules/constellation/pantheon-gamemode.nix:17`
- Modify: `tests/router-test.nix:120`
- Modify: `CLAUDE.md` (Flake Structure → `lib.nix` bullet)

**Interfaces:**
- Consumes: `/tmp/flake-structure/drvs.sh`, `/tmp/flake-structure/before/*` from Task 1.
- Produces: `self.lib.loadPackages :: pkgs -> attrset of derivations` (one attr per `packages/<name>/package.nix`), used by both the host overlay and `perSystem.packages`.

- [ ] **Step 1: Record the current package attribute names**

```bash
cd /home/arosenfeld/Code/nixos
nix eval --json .#packages.x86_64-linux --apply builtins.attrNames | jq -r '.[]' > /tmp/flake-structure/pkgnames-before
ls -d packages/*/ | xargs -n1 basename > /tmp/flake-structure/pkgdirs
diff /tmp/flake-structure/pkgnames-before /tmp/flake-structure/pkgdirs && echo SAME
```

Expected: `SAME` (18 names). If haumea's output differs from the directory list, note the difference — the new loader must yield exactly the directory list.

- [ ] **Step 2: Rename every package entry point**

```bash
for d in packages/*/; do git mv "$d/default.nix" "$d/package.nix"; done
git status --short | grep -c '^R'
```

Expected: `18`. At this point evaluation is broken (haumea and the two direct paths look for `default.nix`) — that is the failing state.

- [ ] **Step 3: Replace `loadPackages` in `flake-modules/lib.nix`**

Replace:

```nix
    # Define packages loading function once
    loadPackages = pkgs: let
      loaded = inputs.haumea.lib.load {
        src = ../packages;
        loader = inputs.haumea.lib.loaders.callPackage;
        inputs = {inherit pkgs;};
      };
    in
      builtins.mapAttrs (name: value:
        if value ? default
        then value.default
        else value)
      loaded;
```

with:

```nix
    # packages/<name>/package.nix, the nixpkgs by-name layout. Other files in a
    # package directory (module.nix, sources) are ignored by the loader.
    loadPackages = pkgs:
      pkgs.lib.packagesFromDirectoryRecursive {
        inherit (pkgs) callPackage;
        directory = ../packages;
      };
```

and change the overlay comment `# Load packages from ./packages directory using haumea` to `# Load packages from ./packages`.

- [ ] **Step 4: Replace the loader in `flake-modules/dev.nix`**

Replace lines 140-146:

```nix
    # Expose packages loaded via haumea
    packages = inputs.haumea.lib.load {
      src = ../packages;
      loader = inputs.haumea.lib.loaders.callPackage;
      inputs = {inherit pkgs;};
      transformer = inputs.haumea.lib.transformers.liftDefault;
    };
```

with:

```nix
    packages = self.lib.loadPackages pkgs;
```

- [ ] **Step 5: Repoint the two direct references**

`modules/constellation/pantheon-gamemode.nix:17`:

```nix
      (pkgs.callPackage ../../packages/wingpanel-indicator-gamemode/package.nix {})
```

`tests/router-test.nix:120`:

```nix
          network-metrics-exporter = final.callPackage "${self}/packages/network-metrics-exporter/package.nix" {};
```

Then confirm nothing else names a package directory as a callPackage target:

```bash
grep -rn "packages/[A-Za-z0-9_-]*\(\"\|/default.nix\| {\)" --include=*.nix --include=justfile . | grep -v '^./docs\|^./.git'
```

Expected: no output (the `module.nix` imports under `hosts/router` don't match and are unaffected).

- [ ] **Step 6: Update `CLAUDE.md`**

In "### Flake Structure", change the `lib.nix` bullet from:

```markdown
- **`lib.nix`** - Core utilities: `mkLinuxSystem`, overlays, `baseModules`, `homeManagerModules`. Uses **haumea** to recursively auto-load all files from `modules/` and `packages/` directories.
```

to:

```markdown
- **`lib.nix`** - Core utilities: `mkLinuxSystem`, overlays, `baseModules`, `homeManagerModules`. Uses **haumea** to auto-load every file under `modules/`, and `lib.packagesFromDirectoryRecursive` to load `packages/<name>/package.nix` (the nixpkgs by-name layout; other files in a package directory are ignored).
```

In "### Directory Structure", change `- `packages/` - Custom Nix derivations (auto-loaded by haumea)` to `- `packages/` - Custom Nix derivations, one `<name>/package.nix` each (auto-loaded)`.

- [ ] **Step 7: Format and verify the package set**

```bash
just fmt
nix eval --json .#packages.x86_64-linux --apply builtins.attrNames | jq -r '.[]' > /tmp/flake-structure/pkgnames-after
diff /tmp/flake-structure/pkgdirs /tmp/flake-structure/pkgnames-after && echo SAME
nix build --no-link .#wingpanel-indicator-gamemode
```

Expected: `SAME`; the build succeeds (substituted or built).

- [ ] **Step 8: Verify no closure changed**

```bash
/tmp/flake-structure/drvs.sh /tmp/flake-structure/task3
diff -r /tmp/flake-structure/before /tmp/flake-structure/task3 && echo IDENTICAL
```

Expected: `IDENTICAL`. If a host differs, run `nix-diff` as in Task 2 Step 12. A likely cause is a package whose `default.nix` took an argument haumea supplied but `callPackage` resolves differently (e.g. one named `pkgs`); fix the package, don't paper over it.

- [ ] **Step 9: Verify the two checks that reference package paths are unchanged**

Do NOT run `nix flake check` (it evaluates every host and builds every VM test — too heavy for raider). Instead compare the check derivations against the baseline the controller recorded in `/tmp/flake-structure/before/checks`:

```bash
for c in router-test pantheon-gamemode-test; do
  echo "$c $(nice -n 19 nix eval --raw .#checks.x86_64-linux.$c.drvPath)"
done > /tmp/flake-structure/task3-checks
diff /tmp/flake-structure/before/checks /tmp/flake-structure/task3-checks && echo IDENTICAL
```

Expected: `IDENTICAL` — the tests evaluate to the same derivations, so they would pass exactly as before.

- [ ] **Step 10: Commit**

```bash
git add -A packages flake-modules/lib.nix flake-modules/dev.nix \
  modules/constellation/pantheon-gamemode.nix tests/router-test.nix CLAUDE.md
git commit -m "refactor(modules): load packages/ with packagesFromDirectoryRecursive"
```

- [ ] **Step 11: Push**

```bash
git push -u origin master
```

No deploy: identical drvPaths mean identical systems.
