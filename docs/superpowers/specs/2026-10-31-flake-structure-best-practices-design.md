# Flake structure: targeted best-practice fixes

## Context

A comparison of this flake against current community practice for NixOS flakes
(flake-parts, the "dendritic" pattern, nixpkgs' by-name layout, the
stable/unstable mixing threads on Discourse) found the overall shape sound:
auto-discovered hosts, auto-loaded enable-gated modules, a written rule for
host-local versus shared code, overlays defined once, `follows` everywhere it
belongs, and one evaluation path shared by deploy and CI.

Two divergences are worth fixing now:

1. **Six private instances of nixpkgs-unstable.** `modules/constellation/desktop.nix`,
   `modules/constellation/backrest.nix`, `hosts/galactica/configuration.nix`,
   `hosts/galactica/backup/rustic.nix`, `hosts/galactica/services/immich.nix`
   and `home/home.nix` each `import inputs.nixpkgs-unstable`. Every one is a
   full nixpkgs evaluation per host, they disagree on `allowUnfree` (backrest
   and rustic omit it), and none sees `self.lib.overlays`. The last point is
   not a live security gap: the brotli graft lists `inputs.nixpkgs-unstable`
   as a candidate explicitly, and no call site takes bun or cloudflared from
   unstable. It is a trap for the next overlay.
2. **`packages/` is loaded by haumea's `callPackage` loader**, with a
   `value ? default` mapper in `lib.nix` and a `liftDefault` transformer in
   `dev.nix` to undo haumea's nesting. nixpkgs ships
   `lib.packagesFromDirectoryRecursive` for exactly this layout.

Deliberately out of scope: a dendritic migration (large, mostly stylistic),
exporting `nixosModules`, removing `with lib;`, moving per-host metadata
(`unstableHosts`, `lightHosts`, `tiers`, `ciExcludedHosts`) into host
directories, and splitting blackbird's configuration.

## Design

### 1. `pkgs.unstable` overlay

Add to `self.lib.overlays` in `flake-modules/lib.nix`:

```nix
(final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (final.stdenv.hostPlatform) system;
    inherit (final) config;
  };
})
```

- `config` is inherited from the host's package set, so `allowUnfree` and any
  future `nixpkgs.config` setting have one source of truth.
- No overlays are applied to `unstable`. What is taken from it is plain
  upstream packages, and our overlays (python-packages, openldap, ...) target
  stable and may not evaluate against unstable. The brotli graft keeps
  covering unstable through its existing `inputs.nixpkgs-unstable` candidate;
  brotli's store path does not depend on `config`.
- On raider, which is itself on unstable, `pkgs.unstable` is a second instance
  of the same nixpkgs. Accepted: six instances become one, and special-casing
  raider is not worth it.
- Each of the six call sites drops its `pkgs-unstable` let-binding (and its
  `inputs` argument where nothing else uses it) and uses `pkgs.unstable.<x>`.
  `home/home.nix` gets the overlay through `home-manager.useGlobalPkgs = true`.
- CLAUDE.md gains a short rule: take unstable packages from `pkgs.unstable`;
  never `import inputs.nixpkgs*` inside a module or host file.

### 2. `packages/` via `packagesFromDirectoryRecursive`

- `git mv packages/<name>/default.nix packages/<name>/package.nix` for all 18
  packages. A directory containing `package.nix` is called as one package and
  its siblings (`module.nix`, sources, docs) are ignored.
- `flake-modules/lib.nix`: `loadPackages` becomes
  `pkgs: pkgs.lib.packagesFromDirectoryRecursive { inherit (pkgs) callPackage; directory = ../packages; }`;
  the `value ? default` mapper is deleted.
- `flake-modules/dev.nix`: `perSystem.packages = self.lib.loadPackages pkgs;`,
  replacing the haumea load and `liftDefault`.
- haumea stays as an input; it still loads `modules/`.
- Repoint the two direct directory references that rely on the `default.nix`
  name: `modules/constellation/pantheon-gamemode.nix:17` and
  `tests/router-test.nix:120`, both to `.../package.nix`.
- The `module.nix` imports under `hosts/router` are unaffected.

## Verification

The change is a refactor; no closure should move.

1. Before any edit, record
   `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
   for every host in `self.hosts`.
2. After each commit's edits, re-evaluate and diff. Every drvPath must be
   identical. A difference is investigated and explained before committing,
   not waved through.
3. `nix flake check` passes; `nix build .#wingpanel-indicator-gamemode`
   builds; `just fmt` leaves no diff; `grep -rn "import inputs.nixpkgs" hosts
   modules home` returns nothing.

## Rollout

Two commits straight to master:

- `refactor(modules): provide nixpkgs-unstable once as pkgs.unstable`
- `refactor(modules): load packages/ with packagesFromDirectoryRecursive`

No deploy is required: identical drvPaths mean identical systems.
