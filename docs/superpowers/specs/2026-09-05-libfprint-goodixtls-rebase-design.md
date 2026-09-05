# Rebasing the goodixtls 521d driver onto current libfprint

**Status:** approved 2026-09-05
**Scope:** `packages/libfprint-goodix-521d/default.nix`, plus a new
`arsfeld/libfprint-goodixtls` GitHub fork.

## Problem

`packages/libfprint-goodix-521d/default.nix` pins `infinytum/libfprint` at
`5e14af7f` — a 2021 branch based on upstream libfprint `v1.94.1`. Five years of
upstream drift is absorbed entirely by the Nix derivation, which carries four
`postPatch` rewrites and a warning suppression:

1. `-Wno-incompatible-pointer-types`, masking whatever the 2021 code does that
   modern GCC rejects.
2. Widening the firmware gate from `strcmp` to a `strncmp` prefix match.
3. Rewriting `meson.build`'s `version: '1.94.1'` to `'1.94.9'` so that nixpkgs'
   fprintd 1.94.5 pkg-config gate (`libfprint-2 >= 1.94.9`) passes.
4. Hand-adding `FP_DEVICE_RETRY_TOO_FAST` to `FpDeviceRetry` so fprintd's switch
   compiles.

(3) and (4) are lies told to the build system to make a 2021 library impersonate a
2025 one. They work, but they are exactly the kind of thing that fails silently
later: the version string is a pkg-config label, not a behavioural claim, so a
future fprintd needing genuine post-1.94.9 behaviour would pass the gate and fail
at runtime instead of at build time.

Rebasing onto a current upstream deletes both lies outright.

## Why not `git rebase`

The fork's branch is roughly 130 commits between `v1.94.1` and `5e14af7f`,
interleaving three sub-forks (`rootd`, `0x00002a`, `infinytum`) with merge commits
and repeated `Update` / `save` / `C error` commits over the same files. Rebasing
that onto a 2026 base means hundreds of conflicts to produce a history nobody will
read.

The *net* delta is small enough to make that unnecessary. `v1.94.1..5e14af7f`
touches 23 files, of which only five matter:

| Path | Nature |
|---|---|
| `libfprint/drivers/goodixtls/` (12 files, ~4.4k lines) | self-contained, new |
| `meson.build` | driver + helper registration |
| `libfprint/meson.build` | driver/helper source lists |
| `libfprint/fprint-list-udev-hwdb.c` | drop 5110/521d from the unsupported list |
| `data/autosuspend.hwdb` | same, plus autosuspend entries |

The rest is `.vscode/`, `FUNDING.yml`, `.gitignore`, and a `README` line.

So: branch from upstream, apply the net delta as a few clean commits.

## Base: upstream `v1.94.100`

Chosen over `v1.94.10` (which is what nixpkgs ships) deliberately.

The concern with jumping past nixpkgs' own version is that nixpkgs' fprintd 1.94.5
is only *tested* against libfprint 1.94.10. That concern does not survive contact
with the diff: **the public headers are byte-identical between `v1.94.10` and
`v1.94.100`.** `git diff v1.94.10 v1.94.100 -- libfprint/fp-device.h fp-print.h
fp-context.h fp-image.h fp-image-device.h` is empty. fprintd sees exactly the API
nixpkgs tests it against.

The driver-facing internal headers drifted only additively across the entire
`v1.94.1 -> v1.94.100` span:

- `fpi-ssm.h`: `+ fpi_ssm_silence_debug()`
- `fpi-device.h`: doc comments, a `fpi_device_emulation_mode_enabled` debug macro,
  a commented-out declaration removed
- `fpi-image.h`: `FPI_IMAGE_NONE` / `FPI_IMAGE_PARTIAL` added; `FpImage.ref_count`
  replaced by `detection_in_progress` (the driver does not touch either)

Every symbol the driver calls — `fpi_ssm_*`, `fpi_image_device_*`,
`fpi_assemble_frames`, `fpi_do_movement_estimation`,
`fpi_device_class_auto_initialize_features` — is intact.

### The one real cost

`v1.94.100` replaced the `default_drivers` list plus `driver_helper_mapping` dict
with a single `drivers_info` dict, so the fork's top-level `meson.build` hunk is
rewritten rather than applied. It comes out *smaller*, because upstream grew its
own `openssl` helper branch (for uru4000, `>= 3.0`) that we reuse:

```meson
'goodixtls511':  { 'helper': ['openssl', 'goodixtls'] },
'goodixtls52xd': { 'helper': ['openssl', 'goodixtls'] },
'goodixtls53xd': { 'helper': ['openssl', 'goodixtls'] },
```

Only a `threads` branch is genuinely new, for the driver's `pthread_create` TLS
serve thread. `libfprint/meson.build` still has the `driver_sources` /
`helper_sources` dicts, so that hunk applies verbatim.

Registering the drivers as non-optional (i.e. in `default_drivers`) matches what
the fork did and follows uru4000's precedent of pulling OpenSSL into a default
build.

## Fork layout

`gh repo fork infinytum/libfprint` -> `arsfeld/libfprint-goodixtls`, branch
`goodixtls-521d-1.94.100`, which shares history with both the source fork and
upstream. Three commits:

1. **`goodixtls: import TLS drivers from infinytum/libfprint@5e14af7`** — the
   driver directory verbatim (511, 52xd, 53xd, plus shared `goodix.c`,
   `goodix_proto.c`, `goodixtls.c`) and the four integration hunks.
2. **`goodixtls52xd: accept any GFUSB_GM168SEC_APP_ firmware`** — the gate
   widening, baked in.
3. **`goodixtls: fix incompatible pointer types`** — real fixes replacing the
   `-Wno-incompatible-pointer-types` suppression.

All three drivers are carried for fidelity; only `goodixtls52xd` is compiled and
verified, since the Nix derivation passes `-Ddrivers=goodixtls52xd`.

## Resulting derivation

`postPatch` disappears entirely, as does `env.NIX_CFLAGS_COMPILE`. What remains is
a `fetchFromGitHub` at the new rev plus the existing `mesonFlags`. `nss` leaves
`buildInputs` — upstream moved uru4000 off NSS, and we build only goodixtls52xd.

The long comment block justifying the version-gate rewrite is deleted rather than
rewritten: it documented a problem that no longer exists.

`hosts/blackbird/configuration.nix` is untouched. It consumes the package through
`pkgs.fprintd.override { libfprint = pkgs.libfprint-goodix-521d; }`, which is
unaffected by the rebase. Its "five-year-old libfprint fork" comment becomes stale
and gets corrected.

## Verification

- `nix build .#nixosConfigurations.blackbird.pkgs.libfprint-goodix-521d`
- the fprintd override blackbird actually consumes

Enrollment cannot be verified here — it needs a finger on the sensor. The build
result is reported; the hardware check is left to the user.

## Known risks

1. **The pointer-type fixes are unscoped until first compile.** Whether they are
   cosmetic (`guint8 *` vs `gchar *`) or hide something real is unknown. If any
   turn out to be genuine bugs, stop and report rather than silently "fix".
2. **OpenSSL 3.0 deprecations.** The driver calls `SSL_library_init`,
   `SSL_load_error_strings`, and `SSL_CTX_set_ecdh_auto`, all deprecated in 1.1.0
   but still present in 3.x. The current package already builds against nixpkgs'
   OpenSSL 3, so warnings are expected, not errors.
3. **Runtime behaviour is unchanged by construction but unproven in practice.**
   The sensor's PSK and firmware situation is documented in
   `2026-09-05-goodix-521d-fingerprint-design.md`; nothing here changes it.

## Outcome (2026-09-05)

Delivered. `arsfeld/libfprint-goodixtls`, on `master` (the repo's default branch, so the
fork's landing page shows this work rather than inherited upstream content).
`goodixtls-521d-1.94.100` is kept as a same-content branch. Head `6c078afe`.

Five commits, not the three planned:

1. `build: fix drivers_tests iteration when introspection is disabled`
2. `goodixtls: import the Goodix TLS drivers from infinytum/libfprint`
3. `goodixtls: fix incompatible pointer types`
4. `goodixtls52xd: accept any GFUSB_GM168SEC_APP_ firmware`
5. `README: explain what this fork is`

`master` was force-pushed from the inherited `infinytum/libfprint` history,
which shares no ancestry with a `v1.94.100` base. Nothing was lost: that
history still exists in the source fork and in the network.

The repository is named `libfprint-goodixtls`, not `libfprint`. A fork
inherits the upstream name, which makes it read as canonical libfprint in
search results, in `fetchFromGitHub` calls and in anyone's clone list.
`goodixtls` matches the driver directory it carries and covers all three
sensors, rather than only the `521d` the Nix package builds. GitHub keeps a
redirect from the old name, but every reference here was updated rather than
left to depend on it.

The README banner leads the file so it is the first thing GitHub renders. It
states the base version, the three sensor PIDs, the provenance, and — the part
that matters to anyone considering this fork — that only `goodixtls52xd` is
tested, on one machine, and that the sensor's TLS channel is keyed with a
zero PSK.

### The extra commit: v1.94.100 cannot configure with introspection disabled

`tests/meson.build:295` iterates the `drivers_tests` **dict** with a single
loop variable, in the branch taken when introspection bindings are missing:

```
tests/meson.build:295:25: ERROR: Foreach expects exactly 2 variables for
iterating over objects of type dict
```

This is an upstream bug in v1.94.100, not something the port introduced —
confirmed by configuring a pristine `v1.94.100` worktree with a stock driver
(`-Ddrivers=goodixmoc -Dintrospection=false`), which fails identically. It is
invisible to nixpkgs because nixpkgs builds libfprint *with* introspection;
this derivation passes `-Dintrospection=false`, so it hits it. The
introspection-enabled branch at line 195 already uses the correct
two-variable form, so the fix is a one-line typo correction. Worth sending
upstream.

### The pointer-type fixes were not uniform

Three call sites, two different correct answers, which a blanket fix gets
wrong:

- `goodix52xd.c` / `goodix53xd.c`: `payload` is a `guint8` array, so `&payload`
  has type `guint8 (*)[10]`. Pass the array.
- `goodix511.c`: `payload` is a `GoodixDefault` **struct**, so `&payload` was
  correct and needed only an explicit `(guint8 *)` cast. Dropping the `&` here
  — the obvious uniform fix — is a genuine error, and the compiler caught it.
- `goodix.c:181`: implicit `guint8 *` to `GoodixPresetPskResponse *`; the
  struct is `__attribute__((__packed__))`, so an explicit cast is safe.

All are type errors, not logic errors: generated code is unchanged.

### `data/autosuspend.hwdb` was regenerated, not hand-edited

Upstream's `sync-udev-hwdb` target is the wrong tool here — it first runs
`scripts/sync-unsupported-devices.py`, which re-downloads the unsupported list
from the freedesktop wiki and would put 5110/521d/538d straight back. The file
was instead produced by building the `udev-hwdb` custom target against a
`-Ddrivers=default` build and copying its output, which is exactly what
`tests/test-generated-hwdb.sh` diffs against.

The fork was also internally inconsistent here: it removed `538d` from
`data/autosuspend.hwdb` but left it in `fprint-list-udev-hwdb.c`. Since all
three drivers are carried, all three PIDs now leave the allowlist in both
places.

### Unfixed pre-existing bug, reported not patched

`goodix52xd.c:654` and `goodix53xd.c:644`:

```c
guint16 payload = {0x05, 0x03};
goodix_send_write_sensor_register(dev, 556, payload, write_sensor_complete, ssm);
```

`payload` is a scalar `guint16`, and `goodix_send_write_sensor_register` takes
`guint16 value`. The braced initializer sets it to `0x0005` and **silently
discards `0x03`** (`warning: excess elements in scalar initializer`). The
intent was plausibly `0x0305`.

This was deliberately left alone. It is pre-existing behaviour in the driver
that currently works on blackbird, and "fixing" it would change what gets
written to sensor register 556 during the scan state machine — a runtime
behaviour change smuggled in under a rebase. It should be investigated
separately, against the hardware.

### Also unchanged: OpenSSL

No deprecation warnings at all against OpenSSL 3.6.3, despite the driver's
2021-era `SSL_library_init` / `SSL_load_error_strings` / `SSL_CTX_set_ecdh_auto`
calls. `-Wno-incompatible-pointer-types` is gone with nothing put in its place.

### Derivation

`postPatch` and `env.NIX_CFLAGS_COMPILE` are gone. `nss` left `buildInputs`;
`cairo` and `python3` were added (the current tree needs them). The built
library reports `Version: 1.94.100` to pkg-config natively.

### Verification performed

- `nix build .#nixosConfigurations.blackbird.pkgs.libfprint-goodix-521d` — ok
- `.#nixosConfigurations.blackbird.config.services.fprintd.package` — fprintd
  1.94.5 builds against it, with no version-gate rewrite and no hand-added
  `FP_DEVICE_RETRY_TOO_FAST`
- `.#nixosConfigurations.blackbird.config.system.build.toplevel` — ok

Not verified: enrollment and verification against the physical sensor.
