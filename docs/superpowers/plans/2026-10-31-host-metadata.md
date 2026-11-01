> Superseded by 2026-10-31-dendritic-restructure-design.md; never built.

# Per-host metadata in `hosts/<name>/host.nix` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `unstableHosts`, `lightHosts`, `tiers` and `ciExcludedHosts` out of `flake-modules/` into an optional plain-data `hosts/<name>/host.nix` per host, without changing any flake output or any host's nixpkgs/home-manager choice.

**Architecture:** `flake-modules/hosts.nix` reads each host's `host.nix` during discovery, merges it over defaults into `hostMeta.<name>` (rejecting unknown keys), and derives the four existing list/attrset outputs from `hostMeta`. `nixosConfigurations` takes its inputs from `hostMeta`. `lightHosts` moves from `flake.lib` to a top-level output.

**Tech Stack:** Nix flakes, flake-parts, nixpkgs `lib`.

**Spec:** `docs/superpowers/specs/2026-10-31-host-metadata-design.md`

## Global Constraints

- Keys in `host.nix`: `nixpkgs` (`"stable"` | `"unstable"`, default `"stable"`), `homeManager` (bool, default `true`), `tier` (string or null, default `null`), `ci` (bool, default `true`). Nothing else.
- Flake outputs `unstableHosts`, `tiers`, `ciExcludedHosts`, `ciMatrix` keep their names and contents; `lightHosts` becomes a top-level output with the same members; `hostMeta` is added.
- Do not touch the justfile, `.github/workflows/build.yml` or `modules/constellation/gaming.nix`.
- Do **not** use toplevel `drvPath` equality as evidence: the flake source path is in every closure, so every commit changes every drvPath. Use the fingerprint in Step 1.
- New files must be `git add`ed (or `git add -N`) before any `nix eval`, or the flake cannot see them.
- Commit straight to `master`; no branches or worktrees. Conventional commit, never mention Claude.
- Run `just fmt` (alejandra) before committing.

---

### Task 1: Move per-host settings into `host.nix`

**Files:**
- Create: `hosts/raider/host.nix`, `hosts/galactica/host.nix`, `hosts/basestar/host.nix`, `hosts/cylon-link/host.nix`, `hosts/raspi3/host.nix`, `hosts/octopi/host.nix`, `hosts/r2s/host.nix`
- Modify: `flake-modules/hosts.nix` (whole file)
- Modify: `flake-modules/lib.nix:77` (delete `lightHosts` binding) and `:85` (delete it from `inherit`)
- Modify: `CLAUDE.md` ("Host Tiers" section, cylon-link paragraph), `README.md:37`

**Interfaces:**
- Produces flake outputs: `hosts` (list of names), `hostMeta` (`{ <name> = { nixpkgs; homeManager; tier; ci; }; }`), `unstableHosts`, `lightHosts`, `ciExcludedHosts` (lists of names), `tiers` (`{ <tier> = [names]; }`), `ciMatrix` (unchanged shape).

- [ ] **Step 1: Capture the baseline fingerprint (before any edit)**

Run from a clean tree at the current commit:

```bash
cd ~/Code/nixos
fingerprint() {
  local out=$1 light=$2
  mkdir -p "$out"
  nix eval --json .#nixosConfigurations --apply 'cs: builtins.mapAttrs (n: c: {
    version = c.config.system.nixos.version;
    homeManager = c.options ? home-manager;
  }) cs' > "$out/hosts.json"
  for a in tiers unstableHosts ciExcludedHosts ciMatrix; do
    nix eval --json ".#$a" > "$out/$a.json"
  done
  nix eval --json ".#$light" | jq 'sort' > "$out/lightHosts.json"
}
fingerprint /tmp/host-meta/before lib.lightHosts
cat /tmp/host-meta/before/*.json
```

Expected: `hosts.json` shows raider at `26.11.…` and every other host at `26.05.…`; `homeManager` false for cylon-link, octopi, r2s, raspi3. `tiers.json` is `{"tier1":["basestar","galactica","raider"]}`, `unstableHosts.json` `["raider"]`, `ciExcludedHosts.json` `["cylon-link"]`.

- [ ] **Step 2: Create the seven `host.nix` files**

`hosts/raider/host.nix`:
```nix
# Per-host flake settings, read by flake-modules/hosts.nix before the
# configuration is evaluated. Keys: nixpkgs, homeManager, tier, ci.
{
  nixpkgs = "unstable";
  tier = "tier1";
}
```

`hosts/galactica/host.nix` and `hosts/basestar/host.nix` (identical):
```nix
# Per-host flake settings, read by flake-modules/hosts.nix before the
# configuration is evaluated. Keys: nixpkgs, homeManager, tier, ci.
{
  tier = "tier1";
}
```

`hosts/cylon-link/host.nix`:
```nix
# Per-host flake settings, read by flake-modules/hosts.nix before the
# configuration is evaluated. Keys: nixpkgs, homeManager, tier, ci.
{
  homeManager = false;

  # CI never builds this host. It is cross-compiled for armv7l and its kernel
  # alone outlasts the build job's 120-minute timeout on a GitHub runner.
  # raider builds it in `just deploy` phase 1 instead.
  ci = false;
}
```

`hosts/raspi3/host.nix`, `hosts/octopi/host.nix`, `hosts/r2s/host.nix` (identical):
```nix
# Per-host flake settings, read by flake-modules/hosts.nix before the
# configuration is evaluated. Keys: nixpkgs, homeManager, tier, ci.
{
  homeManager = false;
}
```

Then make them visible to the flake:

```bash
git add -N hosts/*/host.nix
```

- [ ] **Step 3: Rewrite `flake-modules/hosts.nix`**

Replace the whole file with:

```nix
{
  self,
  inputs,
  ...
}: let
  inherit (inputs.nixpkgs) lib;

  # Auto-discover all hosts: directories under hosts/ with a configuration.nix
  hostNames = builtins.attrNames (
    lib.filterAttrs (
      name: type: type == "directory" && builtins.pathExists ../hosts/${name}/configuration.nix
    ) (builtins.readDir ../hosts)
  );

  # Per-host settings from the optional hosts/<name>/host.nix. These are
  # plain data rather than NixOS options because nixpkgs and homeManager
  # choose the inputs passed to nixosSystem, before the configuration exists.
  defaults = {
    nixpkgs = "stable"; # or "unstable"
    homeManager = true;
    tier = null; # deployment tier, for `just deploy @<tier>`
    ci = true; # built by .github/workflows/build.yml
  };

  readHostMeta = name: let
    file = ../hosts/${name}/host.nix;
    meta =
      if builtins.pathExists file
      then import file
      else {};
    unknown = builtins.filter (k: !(defaults ? ${k})) (builtins.attrNames meta);
    merged = defaults // meta;
  in
    if unknown != []
    then throw "hosts/${name}/host.nix: unknown key(s) ${lib.concatStringsSep ", " unknown}; allowed: ${lib.concatStringsSep ", " (builtins.attrNames defaults)}"
    else if !(builtins.elem merged.nixpkgs ["stable" "unstable"])
    then throw "hosts/${name}/host.nix: nixpkgs must be \"stable\" or \"unstable\", got ${builtins.toJSON merged.nixpkgs}"
    else merged;

  hostMeta = lib.genAttrs hostNames readHostMeta;
  hostsWhere = pred: builtins.filter (h: pred hostMeta.${h}) hostNames;
in {
  flake = {
    hosts = hostNames;
    inherit hostMeta;

    # Derived views of hostMeta. Their names are the interface the justfile
    # (`.#tiers`) and CI (`.#ciMatrix`) read; keep them stable.
    unstableHosts = hostsWhere (m: m.nixpkgs == "unstable");
    lightHosts = hostsWhere (m: !m.homeManager);
    ciExcludedHosts = hostsWhere (m: !m.ci);
    tiers = builtins.groupBy (h: hostMeta.${h}.tier) (hostsWhere (m: m.tier != null));

    # CI build matrix, derived from the discovered hosts with auto-detected
    # platforms. Consumed by .github/workflows/build.yml via `nix eval`.
    # aarch64 hosts build on GitHub's free native ARM runners (public repo)
    # instead of slow QEMU emulation, which used to time out at 2h.
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
      (hostsWhere (m: m.ci));

    nixosConfigurations = lib.genAttrs hostNames (
      hostName: let
        meta = hostMeta.${hostName};
        # Check if host has a disko config file
        hasDisko = builtins.pathExists ../hosts/${hostName}/disko-config.nix;
        isUnstable = meta.nixpkgs == "unstable";
      in
        self.lib.mkLinuxSystem {
          enableHomeManager = meta.homeManager;
          nixpkgsInput =
            if isUnstable
            then inputs.nixpkgs-unstable
            else inputs.nixpkgs;
          homeManagerInput =
            if isUnstable
            then inputs.home-manager-unstable
            else inputs.home-manager;
          mods =
            lib.optional hasDisko inputs.disko.nixosModules.disko
            ++ [../hosts/${hostName}/configuration.nix];
        }
    );
  };
}
```

- [ ] **Step 4: Remove `lightHosts` from `flake-modules/lib.nix`**

Delete the line `    lightHosts = ["raspi3" "octopi" "r2s" "cylon-link"];` (line 77) and the `      lightHosts` entry in the `inherit` list (line 85). Confirm nothing else reads it:

```bash
grep -rn "lib.lightHosts" --include=*.nix . ; echo "exit $?"
```

Expected: no matches, `exit 1`.

- [ ] **Step 5: Verify equivalence**

```bash
fingerprint /tmp/host-meta/after lightHosts   # function from Step 1; re-define it if the shell is new
diff -r /tmp/host-meta/before /tmp/host-meta/after && echo IDENTICAL
nix eval --json .#hostMeta | jq -c .
```

Expected: `IDENTICAL`, and `hostMeta` lists all ten hosts with defaults filled in.

- [ ] **Step 6: Verify a typo fails loudly**

```bash
sed -i 's/tier = "tier1";/teir = "tier1";/' hosts/galactica/host.nix
nix eval --json .#tiers 2>&1 | grep -o 'hosts/galactica/host.nix: unknown key(s) teir[^;]*'
sed -i 's/teir = /tier = /' hosts/galactica/host.nix
grep -q 'tier = "tier1"' hosts/galactica/host.nix && echo RESTORED
```

Expected: `hosts/galactica/host.nix: unknown key(s) teir`, then `RESTORED`. Restore with `sed`, never `git checkout`: the file is only intent-to-add, so checkout would restore it empty.

- [ ] **Step 7: Update docs**

`README.md:37`, replace
`Hosts are grouped into deployment tiers (defined in \`flake-modules/hosts.nix\` as \`tiers\`):`
with
`Hosts are grouped into deployment tiers (set by \`tier\` in each \`hosts/<name>/host.nix\`):`

`CLAUDE.md` "Host Tiers": replace the first paragraph with

```markdown
Hosts are grouped into deployment tiers, set per host by `tier = "<name>";` in `hosts/<name>/host.nix` and collected by `flake-modules/hosts.nix` into the `tiers` flake output:
```

and replace the paragraph starting "To add or change a tier" with

```markdown
`hosts/<name>/host.nix` is an optional plain attrset (not a module) holding the settings the flake needs *before* a host's configuration is evaluated: `nixpkgs` (`"stable"`/`"unstable"`), `homeManager` (default `true`), `tier` (default `null`) and `ci` (default `true`). A host with all defaults has no file; an unknown key fails evaluation naming the file. `flake-modules/hosts.nix` derives the `unstableHosts`, `lightHosts`, `tiers` and `ciExcludedHosts` outputs from these (all visible together as `.#hostMeta`); the `@tier` selectors in the justfile and the README table follow from them. The CI build matrix (`.github/workflows/build.yml`) is derived from the `ciMatrix` flake output (every host with `ci = true`, with auto-detected platform) — it is not tier-gated.
```

`CLAUDE.md` cylon-link paragraph: replace
`` `ciExcludedHosts` in `flake-modules/hosts.nix` keeps it out of `` (the line continues with `` `ciMatrix` ``)
with
`` `ci = false` in `hosts/cylon-link/host.nix` keeps it out of ``.

- [ ] **Step 8: Format and commit**

```bash
just fmt
git add hosts/*/host.nix flake-modules/hosts.nix flake-modules/lib.nix CLAUDE.md README.md
git status --short   # only the files above
git commit -m "refactor(modules): move per-host settings into hosts/<name>/host.nix"
```

Expected: pre-commit alejandra hook passes; commit created. No deploy needed.
