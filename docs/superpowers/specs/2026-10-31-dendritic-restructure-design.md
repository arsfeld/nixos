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
rather than relying on the host to import both (`podman` imports `media`,
whose `media.containers` it reads; `backrest` imports `backup-notify` and
`backup-status`, which it used to switch on with `mkDefault true`).

Every feature module carries a `key` (`"modules/<path without .nix>"`), as
`{key = ...; imports = [<module>];}`. flake-parts' `modules` wrapper sets none,
and without one a feature imported from two places declares its options twice
and fails to evaluate. One feature may be defined across several files (`base`
is); each file's key is its own path, so none is mistaken for a duplicate.

`base` is not listed by each host: the host option machinery adds it to every
host, in the position haumea's module list holds today.

Two kinds of module keep a gate of their own, because the gate is not a
`constellation.<x>.enable` switch:

- nixpkgs-style service modules (`blocky`, `services.check-stock`,
  `services.tsnsrv`) keep their `enable`, as nixpkgs' own modules do. A host
  imports the module and enables the service. `media.services` sets
  `services.tsnsrv.enable` itself, so `media` imports `tsnsrv`.
- modules conditioned on another module's state keep that condition:
  `caddy-security` (on caddy), `cloudflared.nix` (an extension of nixpkgs'
  `services.cloudflared`), `pantheon-dock` and `pantheon-gamemode` (on
  Pantheon, imported by `desktop`).

Two conditional enables cannot be expressed as imports and are deleted:
galactica's disabled `vpn-exit-nodes` sets `podman.enable`, and raider's
`project-vms` sets `virtualization.enable`. Both hosts already have both
features on.

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
the nixpkgs idiom for kernel configuration. `hosts/router/xdp-firewall.nix` is
excluded: it has not parsed for some time and nothing imports it. The router
step hides it with a `_` prefix like every other dead file.

### Dead and helper files in host directories

import-tree loads every `.nix` file, so a host directory may hold only modules.
`scripts/dendritic/dendritic.py reach` walks each host's imports from
`configuration.nix` and lists everything else: helpers called with arguments
(`k8s/lib.nix`, r2s's `networking.nix`, the heating `templates.nix` and
`zones.nix`, cylon-link's `boot/package.nix`), tests (cylon-link's
`config-test.nix` and `boot/test.nix`), and files nothing imports (galactica's
`metrics.nix` and `timemachine.nix`, raider's `appimage.nix`, and five of
router's, `xdp-firewall.nix` among them). Each gets a `_` prefix, which keeps
it as it is. Deleting the dead ones is a separate decision.

`tests/router-test.nix` imports three router files as NixOS modules. After
the move it takes each one's `configurations.nixos.router.module` instead.
`tests/router-ipv6-test.nix` is not wired into any check and is left alone.

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
   with `scripts/dendritic/enabled.nix`: each `constellation.*.enable`
   including defaults (`common`, `email`, `netdata-client`, ...), the service
   modules' own `enable`, and the media stack's service counts. Save the table
   as `2026-10-31-dendritic-restructure-enabled.md` next to this spec. Use it,
   not a grep of host files, to decide which hosts import each feature.
4. **Move features one at a time** from `_legacy/` into `modules/<feature>`,
   dropping their `enable` and adding imports to exactly the hosts the table
   lists. Until a host moves in stage 5, its feature list sits next to its
   other legacy metadata in `modules/flake/hosts.nix`. `common`, `users`,
   `sops`, `email`, `systemd-email-notify`, the security grafts,
   `caddy-security` and `cloudflared.nix` merge into `base`. `media/`
   (`config`, `services`, `containers`, `gateway`) moves as one unit because
   its parts reference each other. Once `_legacy/` is empty, haumea goes.
5. **Move hosts one at a time** to `modules/hosts/<name>.nix` and
   `modules/hosts/<name>/`, carrying their metadata onto
   `configurations.nixos.<name>`. Disko is imported by the host itself instead
   of being detected from `disko-config.nix`. blackbird and raider are split
   into concern files as they move, following the split spec.
6. **Clean up.** Delete `specialArgs`, the legacy host lists and `hosts/`,
   and `scripts/dendritic/`. Add the `nixosModules` export. Repoint the
   paths that are hard-coded (`tests/router-test.nix`,
   the pantheon-gamemode package reference, any others a `grep` for
   `hosts/` or `modules/` turns up). Rewrite the
   CLAUDE.md sections on flake structure, module auto-discovery, host tiers,
   adding services and the directory structure, and the README host table
   source. Add a note at the top of the superseded and folded specs.

## Verification

No closure changes at any stage. Every host's toplevel depends on the flake
source, through sops file paths and the flake registry (which also carries the
source's `narHash`, `rev` and `lastModified`), so every commit changes every
`drvPath` and a raw `nix-diff` is mostly noise. Verification uses
`scripts/dendritic/`, tested on octopi while planning:

- `fingerprint.py` rehashes a toplevel's derivation graph bottom-up with the
  self source path, every output path and the registry's `self` entry
  normalized away. A comment-only edit gives the same fingerprint; an added
  `environment.etc` entry does not.
- `--loose` also sorts the tokens of every string, so a pure reordering hashes
  the same. Module order does change in stages 4 and 5: import-tree loads
  files in path order, not in the order of the old `imports` lists. That
  reaches derivations through order-sensitive lists such as `kernelParams`
  (`systemPackages` is sorted, so it does not). A loose-only match is accepted
  only after `fingerprint.py explain` shows nothing but reordering of
  entries whose order has no meaning.
- `verify.sh baseline` records, before stage 1 and **one host at a time** under
  `nice` (evaluating several in parallel ran raider out of memory before),
  each host's graph and fingerprints, plus a snapshot of `hosts`, `tiers`,
  `unstableHosts`, `lightHosts` (sorted), `ciExcludedHosts`, `ciMatrix` and
  the attribute names of `deployTargets`.

After each commit's edits:

1. `verify.sh check` reports `MATCH` for every host, or `LOOSE-ONLY` with an
   `explain` output that has been read and is pure reordering. A `DIFF` is
   explained and resolved before committing.
2. The output snapshot matches byte for byte.
3. Every flake check still evaluates (built in CI by `checks.yml`), and
   `just fmt` leaves no diff.

cylon-link is never built, and its toplevel is never evaluated: evaluating it
builds its armv7l cross toolchain (import-from-derivation). It is compared on
a dump of evaluated settings (units, `/etc` text, users, packages, firewall)
taken with import-from-derivation disabled, which is weaker than a fingerprint
but catches a module gained or lost. `nix flake check` is never run locally:
it evaluates cylon-link and its `cylon-link-config` check.
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
