# elementary Terminal on libghostty-gtk: CI and a signed apt repo

Date: 2026-11-07
Status: implemented

## Goal

Anyone on elementary OS 8 can add one apt source and install elementary
Terminal running on libghostty-gtk (Ghostty's engine instead of VTE), and get
updates through apt as either project moves. Both projects also get ordinary
CI: every push and pull request builds and runs the tests.

Done means:

- `libghostty-gtk` and the Terminal fork build and test on every push and PR.
- A push to `libghostty-gtk`'s `master`, or to the fork's `libghostty-gtk`
  branch, produces `.deb`s as a GitHub Release.
- `https://arsfeld.github.io/apt` serves those debs as a signed apt repo, and
  a clean elementary OS 8 container can add it, `apt-get update` with no
  signature warnings, and install `io.elementary.terminal-ghostty`.

Out of scope: arm64, elementary OS releases other than 8, Launchpad/PPAs,
proposing anything upstream (no tickets, no PRs, to elementary or Ghostty).

## Decisions

| Question | Choice | Why |
|---|---|---|
| Hosting | GitHub Pages on a new repo, `arsfeld/apt` | No infra of ours in the path; free; HTTPS. |
| Package identity | `io.elementary.terminal-ghostty`, `Conflicts`/`Replaces`/`Provides: io.elementary.terminal` | Same-name-higher-version would be silently replaced by elementary's next release (8.1.1 > 8.1.0+ghostty…). An unversioned `Provides` still satisfies `elementary-desktop`'s dependency. |
| libghostty-vt | Linked statically into `libghostty-gtk-1.so` | No Ubuntu release ships libghostty-vt 1.0; static linking avoids a third package and any clash with a future Ubuntu `libghostty-vt`. |
| Targets | elementary OS 8 (`noble`), amd64 | The release and architecture nearly all elementary users run. |
| Build environment | `ghcr.io/elementary/docker:stable` | What elementary's own CI uses: elementary OS 8, with Granite 7 and their PPA. |

## Components

### 1. libghostty-gtk (`arsfeld/libghostty-gtk`, branch `master`)

**Static libghostty-vt.** A meson option `ghostty_static` (default `false`)
makes `meson.build` ask for `dependency('libghostty-vt-static')` and leaves
libghostty-vt out of the generated `.pc`'s `Requires.private`. Without the
second half, `pkg-config --cflags ghostty-gtk-1` fails on any machine that
lacks a libghostty-vt `.pc`, which is every elementary machine. The
installed header must not include `<ghostty/vt.h>`; libghostty is only used
by internal code (`Engine.vala`), and CI checks this by compiling a C file
that includes `ghostty-gtk.h` with only `pkg-config ghostty-gtk-1` flags.

**Building libghostty-vt in CI.** `ci/build-libghostty-vt.sh` downloads, each
pinned by sha256:

- Zig 0.17.0, `https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz`
  (`1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026`)
- libghostty-vt 1.0.0 and its `-deps` tarball from
  `release.files.ghostty.org`, with the hashes the nixos package already pins
  (`packages/libghostty-vt-1/package.nix`).

It builds with the same flags as the nix package (`--system <deps>
-Doptimize=ReleaseFast -Dcpu=baseline`, fresh `ZIG_GLOBAL_CACHE_DIR`) into
`/opt/libghostty-vt`, and exports `PKG_CONFIG_PATH` to it. `-Dcpu=baseline`
matters: a deb built for the CI runner's CPU would crash on older machines.

This means the Debian source package cannot be rebuilt offline from itself;
`debian/README.source` says so and points at the script. Acceptable for a
personal repo, not for Debian proper.

**Packaging, `debian/`.** Source package `libghostty-gtk`, debhelper 13,
`dh --buildsystem=meson` with `-Dghostty_static=true`. Binary packages:

- `libghostty-gtk-1-0`: `libghostty-gtk-1.so.*` and the GSettings schema
  (glib's dpkg trigger compiles it on install).
- `libghostty-gtk-dev`: header, `ghostty-gtk-1.vapi`, `.deps`, `.pc`, the
  `.so` symlink. Depends on `libghostty-gtk-1-0 (= ${binary:Version})`,
  `libgtk-4-dev`, `libglib2.0-dev`, `libpango1.0-dev`.

Version `0.1.0+git<YYYYMMDDhhmmss>.<shortsha>` (commit time in UTC, to the
second, so two builds on one day never sort by hash), written by CI into
`debian/changelog` with `dch` before building. The committed changelog holds
a placeholder entry. The source format is `3.0 (native)`, hence no Debian
revision.

The static link also carries libghostty-vt's own static dependencies
(Highway, simdutf, uucode); `debian/copyright` reproduces their notices.

The meson option cannot simply ask for `dependency('libghostty-vt-static')`:
Meson passes a pkg-config dependency's name to valac as `--pkg`, and there is
no binding by that name. It builds the dependency from that `.pc`'s
`includedir` and `libdir` instead, and passes `--pkg libghostty-vt` itself.

`dh_auto_test` runs the meson tests under a headless weston, as the nixos
package does (fonts pinned through `FONTCONFIG_FILE`, `GSETTINGS_BACKEND`
handled by the tests themselves).

**Workflow, `.github/workflows/ci.yml`.**

- `on: push` (all branches), `pull_request`, `workflow_dispatch`.
- Job `build`: container `ghcr.io/elementary/docker:stable`; build
  libghostty-vt (cached by `actions/cache`, keyed on the pinned hashes);
  install build deps with `mk-build-deps`; all of it in `ci/build-deb.sh`,
  which runs the same locally under `docker run`; `dpkg-buildpackage -b -us -uc`
  (which runs the tests); `lintian` (reported, not fatal); the header check;
  upload the debs as a workflow artifact.
- Job `release`: only on `push` to `master`, after `build`. Creates a GitHub
  Release tagged `deb/<version>` with the debs attached. Uses the default
  `GITHUB_TOKEN` (`contents: write`).

### 2. The Terminal fork (`arsfeld/elementary-terminal`, branch `libghostty-gtk`)

One fork-only commit on top of the port, beside the README commit, so the
port commits themselves stay upstreamable. It:

- adds `debian/`, taken from upstream's `deb-packaging` branch and changed:
  source and binary package `io.elementary.terminal-ghostty`;
  `Build-Depends` `libghostty-gtk-dev` instead of `libvte-2.91-gtk4-dev`;
  `Conflicts`, `Replaces` and `Provides`: `io.elementary.terminal`,
  `pantheon-terminal`; keeps `Provides: x-terminal-emulator`; drops the
  transitional `pantheon-terminal` package and the `dbgsym-migration`
  override; `Maintainer` is the fork's owner, not elementary.
- replaces upstream's workflows. `ci.yml` installs VTE and would fail;
  `release.yml` and `gettext.yml` are elementary's release and translation
  machinery. They are deleted and our `ci.yml` added.

Version `8.1.0+ghostty.git<YYYYMMDDhhmmss>.<shortsha>`, written by CI. The upstream
part comes from `meson.build`'s project version, so a rebase onto 8.1.1
raises it.

**Workflow, `ci.yml`.** Same shape as libghostty-gtk's: `build` on every push
and PR, `release` only on push to `libghostty-gtk`. `build` gets
`libghostty-gtk-dev` and `libghostty-gtk-1-0` from libghostty-gtk's latest
GitHub Release (public; the token only raises the API rate limit) and
`apt-get install`s them before `mk-build-deps`. `LIBGHOSTTY_GTK_DEBS` points
it at local debs instead, for a build before a release exists. Upstream's single test (`UnsafePasteTest`) runs in the
build.

**Lockstep.** An API change in libghostty-gtk breaks the fork's next build
until the fork follows. The fork's CI builds against libghostty-gtk's
*latest* release, so a breaking libghostty-gtk release shows up as a red
fork build, not as a broken apt repo: nothing is published until both build.

### 3. The apt repo (`arsfeld/apt`, served from `gh-pages`)

**Publishing.** `.github/workflows/publish.yml` on `master`:

- `on: schedule` (hourly) and `workflow_dispatch`.
- Reads the latest `deb/*` release of each source repo through the public
  API, downloads any deb not already in the pool, regenerates the indexes
  with `apt-ftparchive`, signs, commits and pushes `gh-pages`. A run with
  nothing new pushes nothing. A push to `master` re-signs regardless.
- `concurrency: publish` so two runs never race on `gh-pages`.

Polling, rather than a dispatch from each source repo, keeps every
credential inside `arsfeld/apt`: no token crosses repos, and the signing key
lives in exactly one repo's secrets. The cost is up to an hour between a
release and its appearance in apt, which `gh workflow run publish -R
arsfeld/apt` skips.

**Repo layout.** `apt-ftparchive`, not reprepro: reprepro keeps a database
between runs, and CI has nowhere to keep it. With `apt-ftparchive` the debs
in `pool/main/<source repo>/` on `gh-pages` are the only state, and
`publish.sh` regenerates `Packages` and `Release` from them on every change.
Codename `noble`, component `main`, architecture `amd64`. It keeps the newest
three versions of each package, so a bad build can be rolled back with
`apt install pkg=<version>`, and signs `InRelease` and `Release.gpg` with
SHA512. The public key is served dearmored at
`/arsfeld.gpg`, and `index.html` / the README carry the install steps:

```sh
sudo curl -fsSLo /usr/share/keyrings/arsfeld.gpg https://arsfeld.github.io/apt/arsfeld.gpg
echo "deb [signed-by=/usr/share/keyrings/arsfeld.gpg] https://arsfeld.github.io/apt noble main" \
  | sudo tee /etc/apt/sources.list.d/arsfeld.list
sudo apt update && sudo apt install io.elementary.terminal-ghostty
```

`signed-by` scopes the key to this one source, rather than trusting it for
every repo on the system as `apt-key` would.

**Signing key.** RSA 4096, no expiry, user id
`arsfeld apt <alex@rosenfeld.one>`, signing-only. RSA rather than ed25519
because every apt in the field accepts it. The armored private key is the
`APT_SIGNING_KEY` Actions secret on `arsfeld/apt`, and it is backed up with
its revocation certificate in `secrets/sops/apt.yaml` in nixos, a new file
whose only recipient is the user key (the same rule as `infra.yaml`; no host
reads it). Losing the secret then costs a re-upload, not a new key that every
installed system would have to be told about.

**Install test.** Job `verify` after `publish`, in a fresh
`ghcr.io/elementary/docker:stable`: adds the source exactly as the README
says, `apt-get update --error-on=any` (noble's apt then
treats signature and key-policy warnings as errors), installs
`io.elementary.terminal-ghostty`, then checks that `io.elementary.terminal`
is not installed, `ldd /usr/bin/io.elementary.terminal` has no `not found`,
and the GSettings schema `io.github.arsfeld.ghostty-gtk` is listed by
`gsettings list-schemas`. It also runs after a publish with nothing new, so
it notices if the published repo breaks.

## Setup steps

Done once, by the implementer with `gh` and sops, except where noted:

1. Generate the key in a throwaway `GNUPGHOME`; write it and the revocation
   certificate to `secrets/sops/apt.yaml` (new `.sops.yaml` rule, user key
   only); set `APT_SIGNING_KEY` on `arsfeld/apt`; delete the throwaway home.
2. Create `arsfeld/apt` (public), push `master` and an initial `gh-pages`,
   and enable Pages from `gh-pages`.
3. Enable Actions on `arsfeld/elementary-terminal`: GitHub disables them on
   forks, and turning them on is a settings-page click (**the user**, unless
   `gh api` can do it, which the implementer tries first).

## Order of work

1. libghostty-gtk: meson option, `debian/`, CI. Green build, first release.
2. Fork: packaging commit, CI. Green build against that release, first
   release.
3. Key, `arsfeld/apt`, publish and verify. First green `verify`.
4. nixos: nothing changes in the packages; this spec and `secrets/sops/apt.yaml`
   are the only nixos commits.

## Risks

- **Zig 0.17 builds can crash with a warm cache** ("reached unreachable
  code"), per libghostty's packaging notes. The script uses a fresh
  `ZIG_GLOBAL_CACHE_DIR`; `actions/cache` caches only the finished
  `/opt/libghostty-vt`, never Zig's cache.
- **elementary's stable image moves.** It tracks elementary OS 8 updates.
  A Granite or GTK bump that breaks the build shows up as a red CI run, which
  is the point.
- **Rebasing the fork.** The packaging commit sits on top of the port, so a
  rebase onto a new upstream release carries it along; conflicts would be in
  `debian/changelog` only, which CI regenerates anyway.
