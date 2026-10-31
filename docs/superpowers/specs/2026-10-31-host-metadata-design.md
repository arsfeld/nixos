# Per-host metadata next to each host

## Context

Four per-host settings live in `flake-modules/` instead of in the host's own
directory:

| setting | where | what it decides |
|---|---|---|
| `unstableHosts` | `flake-modules/hosts.nix` | nixpkgs and home-manager input |
| `lightHosts` | `flake-modules/lib.nix` | whether home-manager is included |
| `tiers` | `flake-modules/hosts.nix` | `just` `@tier` selectors |
| `ciExcludedHosts` | `flake-modules/hosts.nix` | membership of `ciMatrix` |

Adding a host or changing one of these means editing a shared flake module,
and the reasons behind each entry (cylon-link's CI timeout, for one) sit far
from the host they describe. `2026-10-31-flake-structure-best-practices-design.md`
listed this as out of scope; this spec takes it up. Splitting blackbird's and
raider's `configuration.nix` is a separate, later piece of work.

The constraint that shapes the design: `nixpkgs` and `homeManager` choose the
inputs passed to `nixosSystem`, so they are needed *before* the host's
configuration is evaluated. They cannot be NixOS options. The settings must be
plain data the flake reads during discovery.

## Design

### `hosts/<name>/host.nix`

An optional file beside `configuration.nix`, holding a plain attrset (not a
module; it takes no arguments):

| key | type | default | replaces |
|---|---|---|---|
| `nixpkgs` | `"stable"` or `"unstable"` | `"stable"` | `unstableHosts` |
| `homeManager` | bool | `true` | `lightHosts` |
| `tier` | string or null | `null` | `tiers` |
| `ci` | bool | `true` | `ciExcludedHosts` |

A host whose settings are all defaults has no file. Seven hosts get one:

- `raider`: `nixpkgs = "unstable"; tier = "tier1";`
- `galactica`, `basestar`: `tier = "tier1";`
- `cylon-link`: `homeManager = false; ci = false;`, with the CI-timeout
  comment that today sits on `ciExcludedHosts`
- `raspi3`, `octopi`, `r2s`: `homeManager = false;`

`router`, `blackbird` and `pegasus` need none.

### Discovery (`flake-modules/hosts.nix`)

During host discovery, each host's `host.nix` is imported if it exists and
merged over the defaults into `hostMeta.<name>`. Evaluation fails, naming the
file, if a `host.nix` has a key outside the four above or a `nixpkgs` value
other than `"stable"`/`"unstable"`. Without that check a typo such as `teir`
would silently drop a host out of tier 1.

`nixosConfigurations` reads its nixpkgs input, home-manager input and
`enableHomeManager` from `hostMeta` instead of from the lists.

### Outputs

The existing flake outputs remain the interface and keep their names and
contents, now derived from `hostMeta`:

- `unstableHosts`: hosts with `nixpkgs == "unstable"`
- `lightHosts`: hosts with `homeManager == false`. This moves from
  `self.lib.lightHosts` in `lib.nix` to a top-level `flake.lightHosts` next to
  the others; nothing else reads the `lib` attribute.
- `tiers`: hosts grouped by `tier`, omitting null
- `ciExcludedHosts`: hosts with `ci == false`; `ciMatrix` is unchanged in form

`hostMeta` itself is also exposed as a flake output for inspection.

So the justfile (`nix eval .#tiers.<t>`), `.github/workflows/build.yml`
(`ciMatrix`) and the `unstableHosts` reference in `modules/constellation/gaming.nix`
don't change.

### Docs

- CLAUDE.md "Host Tiers": tiers are set by `tier` in `hosts/<name>/host.nix`;
  describe the four keys briefly.
- CLAUDE.md cylon-link section: `ci = false` in `hosts/cylon-link/host.nix`
  instead of `ciExcludedHosts` in `flake-modules/hosts.nix`.
- README.md tier table intro: same pointer change.

## Verification

This is a pure refactor, so it is proven by comparing before and after:

1. `nix eval --json` of `.#tiers`, `.#unstableHosts`, `.#ciExcludedHosts`,
   `.#ciMatrix` and `.#lightHosts` (against the old `.#lib.lightHosts`)
   produces identical output.
2. `drvPath` of `nixosConfigurations.<host>.config.system.build.toplevel` is
   identical for all ten hosts. That shows every system closure is unchanged,
   so no deploy is needed.
3. Adding a stray key to one `host.nix` makes evaluation fail with that file's
   path in the message. Revert afterwards.
4. `just fmt` is clean.

New `host.nix` files must be `git add`ed before evaluating, or the flake will
not see them.

## Rollout

One commit, `refactor(modules): move per-host settings into hosts/<name>/host.nix`.
Nothing to deploy: identical drvPaths mean identical systems.
