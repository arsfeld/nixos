# elementary dock extras: a fork, CI and the apt repo

Date: 2026-11-13
Status: approved design

## Goal

Pantheon's dock with our three features — folder stacks, zoom, sharp icons —
stops being a stack of patches inside nixos and becomes a fork of
`elementary/dock`, built and released by its own CI and published as a `.deb`
to the existing `arsfeld/apt` repo, exactly as elementary Terminal on
libghostty-gtk was (`2026-11-07-elementary-terminal-apt-design.md`). nixos then
pins the fork like any other package.

Done means:

- `arsfeld/elementary-dock`, branch `extras`, builds and runs its tests on
  every push and PR, and a push to `extras` produces a `deb/<version>` GitHub
  Release.
- `https://arsfeld.github.io/apt` serves `io.elementary.dock-extras`, and the
  repo's `verify` job installs it on a clean elementary OS 8 container.
- raider's dock is built from the fork's pinned commit and looks and behaves
  as it does today; `modules/desktop/pantheon-dock/` no longer carries the dock's
  sources or patches.

Out of scope: AppCenter (its progress patch stays in nixos), arm64, elementary
OS releases other than 8, anything upstream (no tickets, no PRs).

## Decisions

| Question | Choice | Why |
|---|---|---|
| Repo | `arsfeld/elementary-dock`, a GitHub fork of `elementary/dock` | Same shape as `arsfeld/elementary-terminal`. |
| Branch | `extras`, on tag `8.3.3` | The version nixpkgs carries today, so raider's dock does not change version in the move. |
| Package identity | `io.elementary.dock-extras`, `Conflicts`/`Replaces`/`Provides: io.elementary.dock` | Same-name-higher-version would be replaced by elementary's next release; the unversioned `Provides` still satisfies `elementary-desktop`. |
| AppCenter patch | Stays in `modules/desktop/pantheon-dock/appcenter/` | Without it the Applications stack simply shows no progress, which the dock already handles. |
| Build environment | `ghcr.io/elementary/docker:stable`, amd64, `noble` | As for the Terminal. |

## Components

### 1. The fork (`arsfeld/elementary-dock`, branch `extras`)

Commits on top of `8.3.3`, in the order the overlay applies them today:

1. **stacks** — `stacks/src` copied to `src/Stacks`, `stacks/hooks.patch` applied.
2. **zoom** — `zoom/src` to `src/Zoom`, `zoom/hooks.patch`.
3. **icons** — `icons/src` to `src/Icons`, `icons/hooks.patch`.
4. **README** — what the fork is and how to install it from apt.
5. **packaging** (fork-only, last so rebases carry it):
   - `debian/` from upstream's `deb-packaging` branch, changed: source and
     binary package `io.elementary.dock-extras`; `Conflicts`, `Replaces`,
     `Provides: io.elementary.dock`; keeps `Depends: gala (>= 8.3.0)`;
     `Maintainer` is the fork's owner.
   - Version `8.3.3+extras.git<YYYYMMDDhhmmss>.<shortsha>` (commit time, UTC),
     written into `debian/changelog` by CI with `dch`; the upstream part comes
     from `meson.build`, so a rebase onto 8.3.4 raises it. Source format
     `3.0 (native)`.
   - Upstream's workflows are deleted and replaced by `ci.yml`: job `build`
     (every push, PR, `workflow_dispatch`) in the elementary container runs
     `ci/build-deb.sh` — `mk-build-deps`, `dpkg-buildpackage -b -us -uc`
     (which runs the meson tests: StackTests, ZoomMathTest, IconMathTest),
     `lintian` reported but not fatal — and uploads the debs; job `release`,
     only on push to `extras`, makes a GitHub Release `deb/<version>` with
     them. `ci/build-deb.sh` runs the same locally under `docker run`.
   - `CLAUDE.md`: the dock-specific half of today's
     `modules/desktop/pantheon-dock/CLAUDE.md` — the test hooks
     (`DOCK_STACKS_OPEN`, `DOCK_STACKS_CLICK`, `DOCK_STACKS_FOLDER`,
     `DOCK_STACKS_FAKE_JOB`, `DOCK_ZOOM_AT`), the Vala pitfalls, icon
     resolution, and GTK 4.22 and elementary's icons. The visual loop itself
     stays documented in nixos, which owns the recipes.

GitHub disables Actions on forks; enable them with `gh api`, or ask the user
to click it if the API refuses.

### 2. The apt repo (`arsfeld/apt`)

- `sources` gains `arsfeld/elementary-dock`.
- `publish.sh`'s `Release` `Description` names both packages.
- `verify` also installs `io.elementary.dock-extras` and checks that
  `io.elementary.dock` is not installed, `ldd /usr/bin/io.elementary.dock`
  has no `not found`, and `gsettings list-keys io.elementary.dock` lists
  `stacks` and `zoom-enabled`.
- README and `index.html` mention the dock in the install steps.

### 3. nixos

- **`packages/elementary-dock-extras/package.nix`**:
  `pantheon.elementary-dock.overrideAttrs` with `version =
  "8.3.3-unstable-<date>"`, `src` from `arsfeld/elementary-dock` at a pinned
  rev, `doCheck = true`. It takes `pantheon` as an argument so the module's
  overlay can call it with the scope's previous attrs (`{pantheon = pprev;}`)
  without recursing into its own override.
- **`modules/desktop/pantheon-dock/default.nix`**: the overlay sets
  `elementary-dock` in the pantheon scope to that package, so the session's
  dock, its gsettings schemas and `tests/pantheon-dock-test.nix` (which
  imports the module alone on plain nixpkgs) all keep working. The appcenter
  override and the `dockStacks`/`dockZoom` options are unchanged. `stacks/`,
  `zoom/` and `icons/` are deleted; the header comment points at the fork.
- **`modules/desktop/pantheon-dock/CLAUDE.md`** keeps the visual loop, the
  post-deploy dconf order and where stack progress comes from, and points at
  the fork's `CLAUDE.md` for the rest.
- **`just pantheon::dock-run`** gains an optional fork checkout: given one, it
  builds that tree (the nix package with `src` overridden to the checkout)
  instead of the pinned rev, so the visual loop works on uncommitted fork
  changes. Without one it runs the pinned package, as today.
- **`justfile` `update-packages`** adds `elementary-dock-extras`, followed with
  `deb_tag_version` and `--version=branch=extras`.
- Root `CLAUDE.md` and `README.md` mention where the dock now lives.

## Order of work

1. Fork, feature commits, packaging, CI. Green build.
2. First release; Actions enabled.
3. `arsfeld/apt`: source, verify. Manual `publish` run, green `verify`.
4. nixos: package, module, recipes, docs. `nix build` of raider's toplevel and
   of `checks.x86_64-linux.pantheon-dock-test`'s dock; `dock-run` + `shot`
   of a stack and the zoom compared with today's.

## Risks

- **elementary OS 8's GTK is older than nixpkgs' 4.22.** The icons feature
  implements `Gtk.SymbolicPaintable`, whose weight-aware method is new in GTK
  4.22, and its comments rely on 4.22's icon helper behaviour. If the noble
  build fails, gate that code on the GTK version at build time (a meson
  `--define` checked with `#if` in Vala) rather than drop the feature. Any
  other API newer than noble's GTK, Granite or libadwaita is handled the same way.
- **Two dock versions in nixpkgs.** Stable and unstable may carry different
  `elementary-dock`; the fork pins its own source, so both build 8.3.3 plus
  the extras. A nixpkgs bump that changes the dock's build inputs can still
  break the override, which shows as a failed build.
- **Rebasing.** A new upstream release means rebasing `extras`; conflicts
  land in the feature commits (mostly zoom's ItemGroup changes) and
  `debian/changelog`, which CI regenerates.
