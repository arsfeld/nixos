# Dendritic restructure

## Context

`2026-10-31-flake-structure-best-practices-design.md` set four changes aside:
a dendritic migration, exporting `nixosModules`, removing `with lib;`, and
moving per-host settings (`unstableHosts`, `lightHosts`, `tiers`,
`ciExcludedHosts`) into host directories. This spec takes up all four as one
piece of work, because the dendritic move decides how the other two are done.
The host's own flake-parts declaration becomes the place for its metadata, and
`flake.modules.nixos` makes the export a single line.

Today `flake.nix` imports seven files from `flake-modules/`, haumea loads every
file under `modules/` into every host, a host turns a feature on with
`constellation.<x>.enable`, and `flake-modules/hosts.nix` discovers hosts from
`hosts/*/configuration.nix`. Modules get `inputs` and `self` through
`specialArgs`.

What the community sources say about layout, checked on 2026-10-31:

- None of them prescribes one. The dendritic README says "The dendritic pattern
  is merely a pattern. It's not a religion, law or a mandate", and asks only
  that each file implement one feature and sit "at a path that serves to name
  that feature" (github.com/mightyiam/dendritic).
- `flake.nix` hands one directory to import-tree, and every `.nix` file under it
  is a flake-parts module. import-tree skips any path containing `/_`
  (github.com/vic/import-tree).
- In mightyiam/infra, the reference config, each host is a thin flat file
  (`modules/computers/<host>.nix`) that imports shared features. A host gets a
  directory only for code no other host uses (`computers/molly/pr-tracker.nix`).
  The host option (`nixos.configurations.<host>`) is defined by that flake, not
  by a framework.
- flake-parts ships `flakeModules.modules`, which provides
  `flake.modules.<class>.<name>` with class checking
  (flake.parts/options/flake-parts-modules.html).

### Superseded and folded work

- `2026-10-31-host-metadata-design.md` and its plan are **superseded**, never
  built. The typed host option below replaces `hosts/<name>/host.nix`.
- `2026-10-31-split-host-configurations-design.md` is **folded into stage 5**:
  blackbird and raider are split into concern files, using that spec's tables,
  as they move. That way each file moves once.

## Design

### Tree

```
flake.nix                      # mkFlake {inherit inputs;} (import-tree ./modules)
modules/
  flake/                       # was flake-modules/: hosts option, deploy, checks, dev, images, infra
  hosts/<name>.nix             # declares the host and its metadata, imports its features
  hosts/<name>/                # code only that host uses: hardware, disko, services/, its media.services
  base/                        # imported by every host: common, users, sops, security, email
  <feature>/ or <feature>.nix  # desktop, gaming, development, podman, backrest, media, k3s, ...
packages/ overlays/ home/ infra/ tests/   # unchanged; not flake-parts modules
```

Shared machinery lives under its feature. A host's *uses* of a feature (for
example galactica's ~37 `media.services` declarations and basestar's sites and
k3s apps) live under `modules/hosts/<name>/`, so the CLAUDE.md rule "code only
one host uses lives with that host" still holds. Files that are not modules
(JSON presets, scripts, `callPackage` functions, `fan-control/`) get a `_`
prefix. Explicit `imports = [./x.nix]` lists inside a directory disappear,
because import-tree loads every file.

### Host option

`modules/flake/hosts.nix` declares `configurations.nixos.<name>` as a typed
submodule:

| key | type | default | replaces |
|---|---|---|---|
| `module` | deferredModule | (required) | `hosts/<name>/configuration.nix` |
| `nixpkgs` | enum `"stable"` `"unstable"` | `"stable"` | `unstableHosts` |
| `homeManager` | bool | `true` | `lightHosts` |
| `tier` | null or string | `null` | `tiers` |
| `ci` | bool | `true` | `ciExcludedHosts` |

The submodule type rejects unknown keys, so a typo like `teir` fails to
evaluate. The comments that today explain an entry (cylon-link's CI timeout)
move next to the setting in the host's file.

Every existing output is derived from this attrset and keeps its name and
shape: `nixosConfigurations`, `hosts`, `tiers`, `unstableHosts`, `lightHosts`
(moves from `flake.lib` to a top-level output), `ciExcludedHosts`, `ciMatrix`,
`deployTargets`. The justfile and `.github/workflows/build.yml` do not change.

### Features: import turns a feature on

A shared feature is `flake.modules.nixos.<feature>`. A host turns it on by
listing `config.flake.modules.nixos.<feature>` in the `imports` of its
`module`. The `enable` option and the `mkIf cfg.enable` wrapper are removed. A
flag stays only where a host actually sets it to `false` to switch something
off (`mediaSync` and `vpn-exit-nodes` today).
Options that carry values keep their `constellation.*` names.

A feature that reads another feature's options imports that feature itself,
rather than relying on the host to import both.

Feature files take `inputs` and `self` from the enclosing flake-parts
arguments, and the NixOS module inside closes over them. `specialArgs` is
removed once nothing in `_legacy/` is left. `home/` keeps
`home-manager.extraSpecialArgs`.

### Export

```nix
# Published for discovery (`nix flake show`). These modules assume this flake's
# `base` module and overlays; they are not built to work in another flake.
flake.nixosModules = config.flake.modules.nixos;
```

### `with lib`

All 41 files with a module-scope or attrset-scope `with lib;` get explicit
`lib.` prefixes, the style the other 49 `lib`-using files already follow
(none use `inherit (lib) ...`). This includes `meta = with lib; {...}` in
`packages/`. Narrow scoped forms such as `structuredExtraConfig = with
lib.kernel; {...}` in `hosts/cylon-link/hardware.nix` stay, because that is
the nixpkgs idiom for kernel configuration.

## Migration stages

Each stage is one or more commits straight to master. Every commit leaves all
ten hosts evaluating to unchanged closures (see Verification), so the weekly
update routine can deploy any commit along the way.

1. **Remove `with lib`.** This is mechanical, and no files move.
2. **Bootstrap.** Add the `import-tree` input and import
   `inputs.flake-parts.flakeModules.modules`. `flake.nix` becomes
   `import-tree ./modules`. `git mv flake-modules modules/flake`, and the
   current NixOS tree moves to `modules/_legacy/`. import-tree skips it, and
   haumea keeps loading it into every host exactly as today. `hosts.nix` gains
   the `configurations.nixos` option. Until stage 5, the old `hosts/` discovery
   and lists feed into that option.
3. **Snapshot what each host has enabled.** Evaluate every host, one at a time,
   for each `constellation.*.enable` and the media stack's equivalents,
   including those that are on by default (`common`, `email`,
   `netdata-client`, `development`, ...). Save the table under
   `docs/superpowers/specs/` next to this spec. Use it, not a grep of host
   files, to decide which hosts import each feature.
4. **Move features one at a time** from `_legacy/` into `modules/<feature>`,
   dropping their `enable` and adding imports to exactly the hosts the table
   lists. `common`, `users`, `sops`, `security` and `email` merge into `base`,
   which every host imports. `media/` (`config`, `services`, `containers`,
   `gateway`) moves as one unit because its parts reference each other.
5. **Move hosts one at a time** to `modules/hosts/<name>.nix` and
   `modules/hosts/<name>/`, carrying their metadata onto
   `configurations.nixos.<name>`. Disko is imported by the host itself instead
   of being detected from `disko-config.nix`. blackbird and raider are split
   into concern files as they move, following the split spec.
6. **Clean up.** Delete `_legacy/`, the haumea input, `specialArgs`, the old
   host lists and `hosts/`. Add the `nixosModules` export. Repoint the
   paths that are hard-coded (`tests/router-test.nix`,
   the pantheon-gamemode package reference, any others a `grep` for
   `hosts/` or `modules/` turns up). Rewrite the
   CLAUDE.md sections on flake structure, module auto-discovery, host tiers,
   adding services and the directory structure, and the README host table
   source. Add a note at the top of the superseded and folded specs.

## Verification

No closure changes at any stage. Before stage 1, record a baseline:

- For each of the ten hosts, **one at a time** under `nice` (evaluating several
  in parallel ran raider out of memory before), the toplevel `.drv`.
- A JSON snapshot of `hosts`, `tiers`, `unstableHosts`, `lightHosts` (sorted),
  `ciExcludedHosts`, `ciMatrix` and the attribute names of `deployTargets`.

After each commit's edits:

1. `nix-diff` each host's toplevel against the baseline, sequentially. The only
   difference allowed is the flake source path, which is in every closure.
   Any other difference is explained and resolved before committing.
2. The output snapshot matches byte for byte.
3. `nix flake check` passes and `just fmt` leaves no diff.
4. After stage 6: no module-scope `with lib;`, and no `haumea`, `specialArgs`,
   `_legacy` or `flake-modules` anywhere in the tree.

New files are invisible to the flake until `git add`ed (`git add -N` is enough
before evaluating).

Expected failure mode: once a host stops importing a feature it never enabled,
code that reads that feature's options unconditionally fails to evaluate on
that host. The error names the option. The fix is for the reading feature to
import the one it depends on, not to load the option everywhere again.

No deploy is required at any stage.

## Out of scope

- Converting `home/` to `flake.modules.homeManager`.
- Making exported modules work outside this flake.
- Any change to `packages/`, `overlays/` or `infra/` beyond `with lib`, and any
  change to justfile recipes or CI workflows.
- Lifting the settings blackbird and raider duplicate (`ntfy-publisher-env`,
  dock stacks, firewall off) into a shared feature.
