# elementary dock extras Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the dock's stacks, zoom and sharp-icons features out of nixos into a fork of `elementary/dock`, built by CI, published as `io.elementary.dock-extras` to `arsfeld/apt`, and pinned back into nixos.

**Architecture:** `arsfeld/elementary-dock` branch `extras` = tag `8.3.3` + one commit per feature + README + a fork-only packaging/CI commit, mirroring `arsfeld/elementary-terminal`'s `libghostty-gtk` branch. `arsfeld/apt` polls its releases. nixos replaces its patch overlay with a package whose `src` is the fork.

**Tech Stack:** Vala/meson, debhelper 13, GitHub Actions in `ghcr.io/elementary/docker:stable`, apt-ftparchive, Nix.

**Spec:** `docs/superpowers/specs/2026-11-13-elementary-dock-extras-design.md`

## Global Constraints

- Fork: `arsfeld/elementary-dock` (GitHub fork of `elementary/dock`), branch `extras`, based on tag `8.3.3`.
- Debian package: source and binary `io.elementary.dock-extras`; `Conflicts`, `Replaces`, `Provides: io.elementary.dock`; `Depends: gala (>= 8.3.0)`.
- Deb version: `8.3.3+extras.git<YYYYMMDDhhmmss>.<shortsha>` (commit time UTC; upstream part read from `meson.build`); format `3.0 (native)`; distribution `noble`.
- Release tag: `deb/<version>`, only on push to `extras`.
- Maintainer / dch identity: `Alexandre Rosenfeld <alex@rosenfeld.one>` (as in the Terminal fork).
- nixos package: `packages/elementary-dock-extras`, version `8.3.3-unstable-<date>`, `doCheck = true`.
- The AppCenter patch stays in `modules/desktop/pantheon-dock/appcenter/`.
- No upstream tickets or PRs. Commit nixos changes straight to master. Conventional commits, never mention Claude.
- Reference implementation for every fork/CI file: `arsfeld/elementary-terminal`, branch `libghostty-gtk` (`ci/build-deb.sh`, `.github/workflows/ci.yml`, `debian/`). Copy its shape; drop everything libghostty-specific.

## Review Focus

1. **noble's GTK lacks `Gtk.SymbolicPaintable.snapshot_with_weight` (GTK 4.22).** `icons/src/IconResolution.vala:78` implements it; on elementary OS 8 valac must not see it. Task 2 owns the gate and the check that the noble build compiles.
2. **Feature tests must run in the deb build.** `stacks`, `zoom-math`, `icon-math` meson tests run under `dh_auto_test`; a build that skips them is not green. Task 2 checks the build log for all three.
3. **The VM test imports the module alone on stable nixpkgs**, without this flake's packages overlay. Task 4 runs `checks.x86_64-linux.pantheon-dock-test`.
4. **The dock binary in the deb replaces stock cleanly.** Installing `io.elementary.dock-extras` on an elementary OS 8 system must remove `io.elementary.dock` and keep `elementary-desktop` installed. Task 3's `verify` checks this.
5. **The schema keys exist in the installed deb** (`stacks`, `zoom-enabled`, `zoom-size`), else GLib aborts on a dconf default. Task 3's `verify` checks `gsettings list-keys`.

---

### Task 1: The fork and its feature commits

Work in `~/Code/elementary-dock` (outside nixos).

**Files (in the fork):**
- Create: `src/Stacks/**` from `modules/desktop/pantheon-dock/stacks/src/`, `src/Zoom/**` from `zoom/src/`, `src/Icons/**` from `icons/src/`
- Modify: whatever each `<feature>/hooks.patch` touches (meson, ItemManager, ItemGroup, schema, …)

**Interfaces:**
- Produces: branch `extras` whose tree equals `8.3.3` + today's three patches + copied sources, byte for byte. Tasks 2 and 4 build from it.

- [ ] **Step 1:** `gh repo fork elementary/dock --fork-name elementary-dock --clone=false`, then `git clone git@github.com:arsfeld/elementary-dock ~/Code/elementary-dock`, `git checkout -b extras 8.3.3`.
- [ ] **Step 2:** For each feature in order stacks → zoom → icons: `git apply <nixos>/modules/desktop/pantheon-dock/<f>/hooks.patch`, `cp -r <nixos>/modules/desktop/pantheon-dock/<f>/src src/<Dest>`, fix the "Copied into the dock's src/<Dest>/ by …" comment in that feature's `meson.build` to say it lives here, commit `feat: <stacks|zoom|sharp icons>` with a body taken from that feature's paragraph in `pantheon-dock/default.nix` (design links become "designed in arsfeld/nixos docs/superpowers/specs/…").
- [ ] **Step 3: Verify the tree matches today's build.** Build the dock from the checkout through nixos's current package with the overlay's patches removed:

```bash
cd ~/Code/nixos
nix build --no-link -L --impure --expr '(builtins.getFlake (toString ./.)).nixosConfigurations.raider.pkgs.pantheon.elementary-dock.overrideAttrs (o: { src = builtins.path { path = /home/arosenfeld/Code/elementary-dock; filter = p: t: baseNameOf p != ".git"; }; patches = []; postPatch = ""; })'
```
Expected: build succeeds, log shows `stacks`, `zoom-math`, `icon-math` tests `OK`.

- [ ] **Step 4:** `git push -u origin extras`. Set `extras` as the fork's default branch: `gh repo edit arsfeld/elementary-dock --default-branch extras`.

### Task 2: Packaging, CI, README, CLAUDE.md (fork)

**Files (in the fork):**
- Create: `debian/{changelog,control,copyright,rules,source/format}` (start from `elementary/dock` branch `deb-packaging`; drop `debian/compat`, use `debhelper-compat (= 13)` in `Build-Depends`)
- Create: `ci/build-deb.sh`, `.github/workflows/ci.yml`
- Delete: every upstream file under `.github/workflows/`
- Create: `README.md` section (keep upstream's README below a fork header), `CLAUDE.md`
- Modify: `src/Icons/IconResolution.vala`, `meson.build` (GTK gate)

**Interfaces:**
- Consumes: branch `extras` from Task 1.
- Produces: GitHub Release `deb/<version>` on `arsfeld/elementary-dock` with `io.elementary.dock-extras_<version>_amd64.deb` (+ dbgsym if dh makes one). Task 3 consumes it.

- [ ] **Step 1: GTK gate.** In top-level `meson.build`: if `gtk_dep.version().version_compare('>=4.22')`, add `--define=HAS_GTK_4_22` to `add_project_arguments(..., language: 'vala')`. Wrap `snapshot_with_weight` in `IconResolution.vala` with `#if HAS_GTK_4_22 … #endif`. Commit into the icons commit (`git commit --fixup` + `git rebase -i --autosquash` is not available non-interactively: use `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash 8.3.3`). Re-run Task 1 Step 3; expected still green.
- [ ] **Step 2: debian/.** `control`: Source/Package `io.elementary.dock-extras`, Maintainer as Global Constraints, Build-Depends `debhelper-compat (= 13), libadwaita-1-dev, libgranite-7-dev, libgtk-4-dev, libwayland-dev, libx11-dev, meson, valac` plus whatever `meson.build` needs that `mk-build-deps` then reveals missing; binary `Depends: gala (>= 8.3.0), ${misc:Depends}, ${shlibs:Depends}`, `Recommends: switcheroo-control`, `Conflicts/Replaces/Provides: io.elementary.dock`. `rules`: `dh $@ --buildsystem=meson`. `changelog`: one placeholder `8.3.3` entry. `source/format`: `3.0 (native)`.
- [ ] **Step 3: `ci/build-deb.sh`** = the Terminal's script minus the libghostty-gtk block, suffix `+extras.git`. **`ci.yml`** = the Terminal's, release branch `extras`.
- [ ] **Step 4: Build locally** (raider has docker):

```bash
cd ~/Code/elementary-dock && git add -A && git commit -m "build: Debian packaging and CI for io.elementary.dock-extras"
docker run --rm -v "$PWD:/src" -w /src ghcr.io/elementary/docker:stable sh -c 'git config --global --add safe.directory /src && ci/build-deb.sh'
```
Expected: `dist/io.elementary.dock-extras_8.3.3+extras.git*_amd64.deb`; log contains `stacks`, `zoom-math`, `icon-math` each `OK`. If valac errors on another API newer than noble, gate it the same way as Step 1 and amend the owning feature commit. Then `git clean -fdx dist` / restore `debian/changelog`.
- [ ] **Step 5: README + CLAUDE.md.** README header: what extras adds, the apt install lines from `arsfeld/apt`'s README with `io.elementary.dock-extras`. `CLAUDE.md`: move from nixos `modules/desktop/pantheon-dock/CLAUDE.md` the test hooks paragraph, "Vala pitfalls that bit here", "Icon resolution", "GTK 4.22 and elementary's icons"; add "build with `ci/build-deb.sh` in docker; the visual loop is `just pantheon::dock-run` in arsfeld/nixos, given this checkout". README commit goes before the packaging commit (reorder with the autosquash rebase trick, or commit README first).
- [ ] **Step 6: Push and enable Actions.** `git push -f origin extras`; `gh api -X PUT repos/arsfeld/elementary-dock/actions/permissions -F enabled=true -f allowed_actions=all`; if refused, ask the user. `gh workflow run ci.yml -R arsfeld/elementary-dock --ref extras`; `gh run watch`. Expected: `build` and `release` green, `gh release list -R arsfeld/elementary-dock` shows `deb/8.3.3+extras.git…`.

### Task 3: arsfeld/apt

**Files (in `arsfeld/apt`, clone to `~/Code/apt`):**
- Modify: `sources`, `publish.sh` (Release `Description`), `.github/workflows/publish.yml` (`verify`), `README.md`, `site/index.html`

**Interfaces:**
- Consumes: Task 2's release.

- [ ] **Step 1:** Add `arsfeld/elementary-dock` to `sources`. Description: `elementary Terminal on libghostty-gtk and the elementary dock with extras, for elementary OS 8`.
- [ ] **Step 2: verify.** After the Terminal checks, add:

```sh
apt-get install -y io.elementary.dock-extras
! dpkg -s io.elementary.dock 2>/dev/null | grep -q '^Status: install ok installed'
! ldd /usr/bin/io.elementary.dock | grep -q 'not found'
for k in stacks zoom-enabled zoom-size; do gsettings list-keys io.elementary.dock | grep -qx "$k"; done
```
If the image ships `io.elementary.dock`, also assert it was removed by the install (that is the point of `Conflicts`).
- [ ] **Step 3:** README/index install lines: `sudo apt install io.elementary.dock-extras`, plus a log-out note (the session picks up the new dock on next login).
- [ ] **Step 4:** Commit, push, `gh workflow run publish -R arsfeld/apt`, `gh run watch`. Expected: publish adds `pool/main/elementary-dock/io.elementary.dock-extras_*.deb`, `verify` green.

### Task 4: nixos

**Files:**
- Create: `packages/elementary-dock-extras/package.nix`
- Modify: `modules/desktop/pantheon-dock/default.nix`, `modules/desktop/pantheon-dock/CLAUDE.md`, `just/pantheon.just` (`dock-run`), `justfile` (`update-packages`), `CLAUDE.md` (features table row for `desktop`), `README.md:165`
- Delete: `modules/desktop/pantheon-dock/{stacks,zoom,icons}/`

**Interfaces:**
- Consumes: the fork rev that Task 2 released.
- Produces: `package.nix` signature `{ pantheon, fetchFromGitHub }: pantheon.elementary-dock.overrideAttrs (…)`.

- [ ] **Step 1: package.nix.** Header comment like `packages/elementary-terminal-ghostty/package.nix` (fork, branch `extras`, rebase on a new release, `just update-packages` follows it, spec path). `version = "8.3.3-unstable-<commit date>"`, `src = fetchFromGitHub { owner = "arsfeld"; repo = "elementary-dock"; rev = <released sha>; hash = <from a fake-hash build>; }`, `doCheck = true`.
- [ ] **Step 2: module.** Overlay: `elementary-dock = final.callPackage ../../../packages/elementary-dock-extras/package.nix {pantheon = pprev;};`. Remove `features` and the patches/postPatch. Header comment: features now live in the fork (one paragraph each, one line), appcenter stays here. `git rm -r` the three feature dirs. `git add -N packages/elementary-dock-extras`.
- [ ] **Step 3: CLAUDE.md (module dir).** Drop the sections moved in Task 2 Step 5; point at the fork's `CLAUDE.md`; the visual loop now runs `just pantheon::dock-run <log> <checkout> VAR=…`.
- [ ] **Step 4: dock-run.** New signature `dock-run log="/tmp/io.elementary.dock.log" src="" *env`. With `src` empty, build `nixosConfigurations.raider.pkgs.pantheon.elementary-dock` as today; else `--impure --expr` the same with `.overrideAttrs { src = builtins.path { path = <src>; filter = …not .git…; }; }`. `src` must be an existing directory, else exit 1 with a message. Update the CLAUDE.md example call.
- [ ] **Step 5: update-packages.** Add `elementary-dock-extras` to the list and a case `cmd=(deb_tag_version "$p" "${cmd[@]}" --version=branch=extras)`. Check `deb_tag_version`'s sed matches `deb/8.3.3+extras…-unstable-<date>` (it does: `[0-9.]+\+[^"]*`). Run `nix develop -c just update-packages elementary-dock-extras`; expected: `current` or a clean `updated` with version `8.3.3-unstable-<date>`.
- [ ] **Step 6: Root docs.** CLAUDE.md `desktop` row and README line 165 mention the dock fork (`arsfeld/elementary-dock`, branch `extras`) like the Terminal's.
- [ ] **Step 7: Verify.**

```bash
nix develop -c just fmt
nice nix build --no-link -L .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock   # tests OK
nice nix build --no-link .#nixosConfigurations.raider.config.system.build.toplevel
nice nix build --no-link -L .#checks.x86_64-linux.pantheon-dock-test
```
One at a time (no parallel host evals). Expected: all succeed; the VM test log shows `DOCK_ZOOM_AT: zooming at 1.5 slots`.
- [ ] **Step 8: Look at it.** `just pantheon::dock-run /tmp/dock.log "" DOCK_STACKS_OPEN=0` then `just pantheon::shot /tmp/dock-stack.png 1000 300 1500 1140`; and `DOCK_ZOOM_AT=3` → `/tmp/dock-zoom.png`. Read both: the stack fans out and the zoomed icons are sharp, as before.
- [ ] **Step 9: Commit** `refactor(modules): the dock's extras move to arsfeld/elementary-dock`, body naming the fork, branch and apt package. Push to master. Deploy raider is the user's call; mention that the dock picks up after re-login.
