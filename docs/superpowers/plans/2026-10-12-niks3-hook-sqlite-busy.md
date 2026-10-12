# niks3-hook SQLITE_BUSY Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop raider's `niks3-hook` auto-upload daemon from dropping store paths with `database is locked (SQLITE_BUSY)` under concurrent post-build hooks.

**Architecture:** Carry a one-hunk patch to upstream niks3's `hook/queue.go` that caps the `database/sql` pool at one connection, applied to the `services.niks3-auto-upload.package` on raider via `overrideAttrs`. The regression test is run against the niks3 source in a scratch copy as a red/green gate; it is not carried, because the hook package's source excludes test files (`srcsNoTests`, `doCheck = false`).

**Tech Stack:** Nix flakes, `buildGoModule`, Go 1.26 (`go` on PATH on raider), `modernc.org/sqlite` v1.59.0.

Spec: `docs/superpowers/specs/2026-10-12-niks3-hook-sqlite-busy-design.md`

## Global Constraints

- Never open a PR or issue on Mic92/niks3. The fix is carried locally only.
- Commit straight to `master`; no branches or worktrees.
- Do not touch the uncommitted `hosts/raider/weekly-update.nix` change; stage files by explicit path only.
- Conventional commits, scope `raider`. Never mention Claude.
- Run `just fmt` (alejandra) before committing Nix.
- A new file is invisible to `nix build` until `git add`ed.

## Evidence already gathered (2026-10-12, during planning)

Against the pinned niks3 (`e64338d7`), `go test ./hook -count=3` with the drain
test below at 64 writers × 50 paths:

| Variant | Result |
|---|---|
| unpatched | FAIL — `inserting path "/nix/store/drain-N-0": database is locked (5) (SQLITE_BUSY)` |
| `&_txlock=immediate` in DSN | FAIL — 154× `begin transaction: … SQLITE_BUSY`, also breaks upstream `TestQueueConcurrentWriters` |
| `db.SetMaxOpenConns(1)` | PASS 3/3 |

At 8 writers × 200 the unpatched code passes; the failure needs the fan-in a
busy `weekly-update` produces. Task 1 re-runs this so the executor sees it
first-hand.

---

### Task 1: Red/green gate in a scratch copy of niks3

**Files:** none in the repo. Scratch dir: `$SCRATCH/niks3` where
`SCRATCH=/tmp/claude-1000/-home-arosenfeld-Code-nixos/f86656a3-51a3-4fcb-af1e-aa7b0a165cc2/scratchpad`.

**Interfaces:**
- Consumes: the pinned niks3 source (`nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.niks3.outPath'`).
- Produces: `$SCRATCH/niks3-hook-single-conn.patch`, the exact patch Task 2 commits.

- [ ] **Step 1: Fresh scratch copy of the pinned source**

```bash
cd /home/arosenfeld/Code/nixos
SCRATCH=/tmp/claude-1000/-home-arosenfeld-Code-nixos/f86656a3-51a3-4fcb-af1e-aa7b0a165cc2/scratchpad
SRC=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.niks3.outPath')
rm -rf "$SCRATCH/niks3" && cp -r "$SRC" "$SCRATCH/niks3" && chmod -R u+w "$SCRATCH/niks3"
```

- [ ] **Step 2: Write the failing test** at `$SCRATCH/niks3/hook/queue_drain_test.go`

```go
package hook_test

import (
	"fmt"
	"sync"
	"testing"
)

// The daemon's real access pattern: the socket server enqueues while the
// worker drains with FetchBatch then Remove or Retry, all on one Queue.
// 64 writers approximates the post-build-hook fan-in of a weekly-update build.
func TestQueueEnqueueDuringDrain(t *testing.T) {
	t.Parallel()

	q := newTestQueue(t)

	const writers = 64

	const perWriter = 50

	stop := make(chan struct{})
	drainErr := make(chan error, 1)

	go func() {
		defer close(drainErr)

		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}

			paths, err := q.FetchBatch(50)
			if err != nil {
				drainErr <- err

				return
			}

			if i%2 == 0 {
				err = q.Remove(paths)
			} else {
				err = q.Retry(paths)
			}

			if err != nil {
				drainErr <- err

				return
			}
		}
	}()

	var wg sync.WaitGroup

	errs := make(chan error, writers)

	for w := range writers {
		wg.Add(1)

		go func(w int) {
			defer wg.Done()

			for i := range perWriter {
				if err := q.Enqueue([]string{fmt.Sprintf("/nix/store/drain-%d-%d", w, i)}); err != nil {
					errs <- err

					return
				}
			}
		}(w)
	}

	wg.Wait()
	close(stop)
	close(errs)

	for err := range errs {
		t.Errorf("Enqueue during drain: %v", err)
	}

	if err := <-drainErr; err != nil {
		t.Errorf("drain: %v", err)
	}
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd $SCRATCH/niks3 && go test ./hook -run TestQueueEnqueueDuringDrain -count=3 2>&1 | grep -E '^(ok|FAIL)|SQLITE_BUSY' | sort | uniq -c`
Expected: `FAIL` with `Enqueue during drain: inserting path … database is locked (5) (SQLITE_BUSY)`.
**If it passes, stop.** The diagnosis is wrong; report back instead of continuing.

- [ ] **Step 4: Write the patch** to `$SCRATCH/niks3-hook-single-conn.patch` (exact content):

```diff
--- a/hook/queue.go	2026-10-12 14:26:03.837111179 -0400
+++ b/hook/queue.go	2026-10-12 14:26:03.842651003 -0400
@@ -34,6 +34,12 @@
 		return nil, fmt.Errorf("opening database: %w", err)
 	}
 
+	// One connection for the whole process. Only this daemon opens the queue, so
+	// callers wait their turn in database/sql instead of in SQLite's busy
+	// handler, whose backoff starves some waiters past busy_timeout once dozens
+	// of post-build hooks enqueue while the worker drains (SQLITE_BUSY).
+	db.SetMaxOpenConns(1)
+
 	ctx := context.Background()
 
 	// Create the queue table.
```

- [ ] **Step 5: Apply it and run the whole hook suite**

Run: `cd $SCRATCH/niks3 && patch -p1 < ../niks3-hook-single-conn.patch && go test ./hook -count=3 2>&1 | grep -E '^(ok|FAIL)'`
Expected: `ok  github.com/Mic92/niks3/hook` (the suite logs ERROR lines from other tests' deliberate failures; only the final verdict matters).

No commit: nothing in the repo changed.

---

### Task 2: Carry the patch on raider's niks3-hook package

**Files:**
- Create: `hosts/raider/niks3-hook-single-conn.patch` (copy of `$SCRATCH/niks3-hook-single-conn.patch`)
- Modify: `hosts/raider/configuration.nix` — the `services.niks3-auto-upload` block (currently lines 84-88)

**Interfaces:**
- Consumes: `$SCRATCH/niks3-hook-single-conn.patch` from Task 1; the upstream derivation `${inputs.niks3}/nix/packages/niks3-hook.nix` (the module's own default, `pkgs.callPackage ../packages/niks3-hook.nix { }`).
- Produces: `config.services.niks3-auto-upload.package` with the patch applied. The module calls `.override { postBuildHookSocketPath = …; }` on it, which `overrideAttrs` preserves.

- [ ] **Step 1: Copy the patch into the repo and make it visible to the flake**

```bash
cp "$SCRATCH/niks3-hook-single-conn.patch" hosts/raider/niks3-hook-single-conn.patch
git add -N hosts/raider/niks3-hook-single-conn.patch
```

- [ ] **Step 2: Set the package** — replace the `services.niks3-auto-upload` block in `hosts/raider/configuration.nix` with:

```nix
  services.niks3-auto-upload = {
    enable = true;
    serverUrl = "https://niks3.arsfeld.dev";
    authTokenFile = config.sops.secrets."niks3-api-token".path;
    # The hook's SQLite queue drops paths with SQLITE_BUSY once dozens of
    # post-build hooks enqueue while the worker drains (~760 lost during the
    # 2026-10-11 weekly-update). Upstream's DSN-pragma fix for #409 is in the
    # pinned version and is not enough; capping the pool at one connection is.
    # Design: docs/superpowers/specs/2026-10-12-niks3-hook-sqlite-busy-design.md
    # Delete this once the pinned niks3 has an equivalent fix. If upstream
    # changes hook/queue.go the patch stops applying and the build says so.
    package =
      (pkgs.callPackage "${inputs.niks3}/nix/packages/niks3-hook.nix" {}).overrideAttrs
      (old: {patches = (old.patches or []) ++ [./niks3-hook-single-conn.patch];});
  };
```

- [ ] **Step 3: Format**

Run: `just fmt`
Expected: exits 0; `git diff --stat` shows only `hosts/raider/configuration.nix` (plus the pre-existing `weekly-update.nix`).

- [ ] **Step 4: Build the patched package and prove the patch is in it**

```bash
nix eval --impure --expr '
  let f = builtins.getFlake (toString ./.); in
  map baseNameOf f.nixosConfigurations.raider.config.services.niks3-auto-upload.package.patches'
nix build --no-link --print-out-paths --impure --expr '
  let f = builtins.getFlake (toString ./.); in
  f.nixosConfigurations.raider.config.services.niks3-auto-upload.package'
```
Expected: the eval prints a list ending in a `…niks3-hook-single-conn.patch` name; the build succeeds (a patch that fails to apply fails here).

- [ ] **Step 5: Confirm the socket-path override still reaches the binary**

Run: `systemctl cat niks3-auto-upload.service | grep -o 'socket [^ ]*'` (current value), then
`nix build .#nixosConfigurations.raider.config.system.build.toplevel --no-link --print-out-paths` and
`grep -o '/nix/store/[^ ]*niks3-hook-1.4.0' $(nix build .#nixosConfigurations.raider.config.system.build.toplevel --no-link --print-out-paths)/etc/systemd/system/niks3-auto-upload.service`
Expected: the toplevel builds; the unit's niks3-hook store path differs from the running one (`/nix/store/x1z5hgq7…`), and its `--socket` argument is unchanged.

- [ ] **Step 6: Commit**

```bash
git add hosts/raider/niks3-hook-single-conn.patch hosts/raider/configuration.nix
git commit -m "fix(raider): carry single-connection patch for niks3-hook SQLITE_BUSY" -- hosts/raider/niks3-hook-single-conn.patch hosts/raider/configuration.nix
```

---

### Task 3: Activate on raider and confirm

**Files:** none.

- [ ] **Step 1: Activate without changing the boot default**

Run: `just test raider`
Expected: activation succeeds. The daemon is socket-activated, so the new binary is picked up on its next start.

- [ ] **Step 2: Confirm the unit points at the patched build**

Run: `systemctl show niks3-auto-upload.service -p ExecStart --value | grep -o '/nix/store/[^ ]*niks3-hook-1.4.0'`
Expected: the store path from Task 2 Step 5, not `/nix/store/x1z5hgq71vjmv8l24dnl6ii13348gsym-niks3-hook-1.4.0`.

- [ ] **Step 3: Record the baseline for later**

Run: `journalctl -u niks3-auto-upload --since today --no-pager | grep -c SQLITE_BUSY`
Expected: a number (likely 0 today). The real confirmation is after the next heavy build
(the next Sunday weekly-update): the same command with `--since` that run's start should return `0`.
