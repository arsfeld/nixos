# Weekly Update → Deploy Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bot's weekly `flake.lock` commit get a `Build & Cache` run, and move galactica's `weekly-deploy` late enough to find it green.

**Architecture:** `update.yml`'s commit job dispatches `build.yml` on master after pushing, because pushes made with `GITHUB_TOKEN` trigger no workflows. The dispatched run matches what `weekly-deploy`'s gate already queries (name "Build & Cache", `head_sha`, bare `<host>` job names), so the gate is unchanged; only its schedule moves from 06:00 to 12:00 UTC.

**Tech Stack:** GitHub Actions, `gh` CLI, NixOS module (systemd timer), Markdown docs.

Spec: `docs/superpowers/specs/2026-09-24-weekly-update-handoff-design.md`

## Global Constraints

- Commit straight to master; no branches or worktrees.
- Conventional commits: `<type>(<scope>): <subject>`; never mention Claude.
- New schedule value, verbatim: `Sun *-*-* 12:00:00 UTC`.
- Dispatch command, verbatim: `gh workflow run build.yml --ref master`, env `GH_TOKEN: ${{ github.token }}`.
- The dispatch step must NOT be `continue-on-error` and must not be guarded by `|| true`.
- Do not change the gate logic in `weekly-deploy.nix` (the `RUN_ID`/`JOBS_JSON`/`BAD` block).
- Run `just fmt` before committing Nix changes.
- Pushing and deploying are outward-facing: Task 3 steps that push or deploy require the user's go-ahead in the session.

---

### Task 1: `update.yml` dispatches `Build & Cache` after pushing

**Files:**
- Modify: `.github/workflows/update.yml` (the `commit` job, currently lines 54–73)

**Interfaces:**
- Consumes: `build.yml` already declares `workflow_dispatch:` (line 6) — no change there.
- Produces: a `workflow_dispatch`-triggered "Build & Cache" run on master HEAD after every bot lock commit. Task 2's comments describe this.

- [ ] **Step 1: Confirm the failing state**

Run:
```bash
gh api "repos/arsfeld/nixos/actions/runs?head_sha=$(git rev-parse f338debc)" --jq '.total_count'
```
Expected: `0` — the Sep 20 bot commit has no runs at all. This is the defect.

- [ ] **Step 2: Add `actions: write` to the commit job**

In `.github/workflows/update.yml`, replace:
```yaml
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v6

      - name: Commit updated flake.lock
```
with:
```yaml
    permissions:
      contents: write
      # For the dispatch step below.
      actions: write
    steps:
      - uses: actions/checkout@v6

      - name: Commit updated flake.lock
```

- [ ] **Step 3: Add the dispatch step after `git push`**

In the same file, replace:
```yaml
          git pull --rebase origin master
          git push
```
with:
```yaml
          git pull --rebase origin master
          git push

      # A push made with GITHUB_TOKEN starts no workflow runs, so the push above
      # never triggers build.yml on its own. Without this, the bot's lock commits
      # (50b5580, f338deb) got no "Build & Cache" run, and galactica's
      # weekly-deploy gate, which looks for exactly that run by head_sha,
      # skipped every one of them. workflow_dispatch is the documented
      # exception to that rule. Not continue-on-error: a failed dispatch must
      # turn this job red rather than surface as a silent skip on galactica.
      - name: Build and cache the new commit
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh workflow run build.yml --ref master
```

- [ ] **Step 4: Lint the workflow**

Run:
```bash
nix run nixpkgs#actionlint -- .github/workflows/update.yml
```
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/update.yml
git commit -m "ci: dispatch Build & Cache after the weekly lock commit"
```

---

### Task 2: Move `weekly-deploy` to 12:00 UTC and correct its docs

**Files:**
- Modify: `hosts/galactica/weekly-deploy.nix` (header comment lines 8–15, precondition comment lines 238–249, `schedule` option lines 568–572)
- Modify: `CLAUDE.md` (Weekly Automation section, around lines 84–92)

**Interfaces:**
- Consumes: Task 1's dispatch step (referenced in comments only).
- Produces: `config.systemd.timers.weekly-deploy.timerConfig.OnCalendar == "Sun *-*-* 12:00:00 UTC"` on galactica.

- [ ] **Step 1: Write the failing check**

Run:
```bash
nix eval --raw .#nixosConfigurations.galactica.config.systemd.timers.weekly-deploy.timerConfig.OnCalendar
```
Expected now: `Sun *-*-* 06:00:00 UTC` (the check fails until Step 3; target is `Sun *-*-* 12:00:00 UTC`).

- [ ] **Step 2: Correct the header comment**

In `hosts/galactica/weekly-deploy.nix`, replace:
```nix
# avoid racing a commit whose closures are still uploading. That check is scoped
# to the tier-1 build jobs specifically (see the precondition below), not the
# whole "Build & Cache" run's conclusion: the run that fires for master's new
# HEAD rebuilds all nine hosts, and an unrelated octopi/blackbird/router
# failure must not block a tier-1 deploy that already provably built.
```
with:
```nix
# avoid racing a commit whose closures are still uploading. That check is scoped
# to the tier-1 build jobs specifically (see the precondition below), not the
# whole "Build & Cache" run's conclusion: that run rebuilds all nine hosts, and
# an unrelated octopi/blackbird/router failure must not block a tier-1 deploy
# that already provably built. For a human commit the run comes from the push;
# for update.yml's lock commit it is dispatched explicitly, because a push made
# with GITHUB_TOKEN triggers no workflows at all.
```

- [ ] **Step 3: Correct the precondition comment**

Replace:
```nix
    # Precondition: only deploy once every tier-1 host's own build job
    # succeeded in this SHA's latest "Build & Cache" run — not once the
    # whole run is green. A commit landing on master always triggers a
    # fresh, full-fleet "Build & Cache" run (job names are bare "<host>"
    # for all nine hosts); update.yml's own workflow_call invocation
    # nests its jobs as "build / <host>" and only ever covers tier-1.
```
with:
```nix
    # Precondition: only deploy once every tier-1 host's own build job
    # succeeded in this SHA's latest "Build & Cache" run — not once the
    # whole run is green. Every commit landing on master gets a fresh,
    # full-fleet "Build & Cache" run (job names are bare "<host>" for all
    # nine hosts): from the push for human commits, from update.yml's
    # dispatch step for its lock commit. update.yml's own workflow_call
    # invocation nests its jobs as "build / <host>", covers only tier-1,
    # and builds the pre-commit SHA, so it never matches here.
```

- [ ] **Step 4: Change the schedule**

Replace:
```nix
      default = "Sun *-*-* 06:00:00 UTC";
      description = "OnCalendar spec. Must land after the Sunday 00:00 UTC CI run.";
```
with:
```nix
      default = "Sun *-*-* 12:00:00 UTC";
      description = ''
        OnCalendar spec. Must land after the lock commit's dispatched "Build &
        Cache" run finishes: GitHub has started the "00:00 UTC" update cron as
        late as 03:56, the update run takes up to ~1.5 h, and the dispatched
        build another 20-50 min. 06:00 fired before that build was done.
      '';
```

- [ ] **Step 5: Run the check and format**

Run:
```bash
just fmt
nix eval --raw .#nixosConfigurations.galactica.config.systemd.timers.weekly-deploy.timerConfig.OnCalendar
```
Expected: `Sun *-*-* 12:00:00 UTC`

- [ ] **Step 6: Build galactica**

Run:
```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
```
Expected: exit 0.

- [ ] **Step 7: Update CLAUDE.md**

Replace:
```markdown
- **GitHub `Weekly Update`** (Sun 00:00 UTC): `nix flake update`, builds tier-1, commits
  `flake.lock` to master. Gated on tier-1 only — a broken octopi will not block the lock.
```
with:
```markdown
- **GitHub `Weekly Update`** (Sun 00:00 UTC): `nix flake update`, builds tier-1, commits
  `flake.lock` to master. Gated on tier-1 only — a broken octopi will not block the lock.
  Its push uses `GITHUB_TOKEN`, which triggers no workflows, so it then dispatches
  `Build & Cache` on master explicitly; without that run `weekly-deploy` skips the commit.
```
and replace:
```markdown
- **galactica `weekly-deploy`** (Sun 06:00 UTC): pulls master, then runs `nixos-rebuild
```
with:
```markdown
- **galactica `weekly-deploy`** (Sun 12:00 UTC): pulls master, then runs `nixos-rebuild
```

- [ ] **Step 8: Verify no stale 06:00 references remain**

Run:
```bash
grep -rn "06:00" CLAUDE.md hosts/galactica/weekly-deploy.nix .github/workflows/
```
Expected: only the new description's "06:00 fired before that build was done." line.

- [ ] **Step 9: Commit**

```bash
git add hosts/galactica/weekly-deploy.nix CLAUDE.md
git commit -m "fix(galactica): run weekly-deploy after the lock commit's build"
```

---

### Task 3: Roll out and verify

**Files:** none modified.

**Interfaces:**
- Consumes: Tasks 1 and 2 committed on master.

- [ ] **Step 1: Push (ask the user first)**

```bash
git push origin master
```
Wait for this push's `Build & Cache` run to go green:
```bash
gh run watch "$(gh run list --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

- [ ] **Step 2: Install the deployer by hand (ask the user first)**

From raider:
```bash
just deploy galactica
```
Then verify:
```bash
ssh galactica.bat-boa.ts.net 'systemctl list-timers weekly-deploy.timer --no-pager'
```
Expected: `NEXT` is Sunday 08:00 EDT (12:00 UTC), give or take the 10-minute randomized delay.

- [ ] **Step 3: Exercise the dispatch path (ask the user first)**

```bash
gh workflow run update.yml
```
Watch it. Two outcomes:
- **No input changes** (`has_changes=false`): `commit` job is skipped, nothing is dispatched. Report that the first real test is Sunday 2026-09-27; stop here.
- **Changes**: the `commit` job's "Build and cache the new commit" step must succeed. Then:
  ```bash
  SHA=$(git ls-remote origin master | cut -f1)
  gh api "repos/arsfeld/nixos/actions/runs?head_sha=$SHA" --jq '.workflow_runs[] | "\(.name) \(.event) \(.status) \(.conclusion)"'
  ```
  Expected: a line `Build & Cache workflow_dispatch …`. Once it is `completed success`, with the user's go-ahead:
  ```bash
  ssh galactica.bat-boa.ts.net 'sudo systemctl start weekly-deploy; sudo jq -r .commit /var/lib/weekly-deploy/last-run.json'
  ```
  Expected: `$SHA`.

- [ ] **Step 4: Post-Sunday check (2026-09-28)**

```bash
ssh galactica.bat-boa.ts.net 'sudo jq -r "\(.commit) \(.ranAt) \(.deployFailedHosts)" /var/lib/weekly-deploy/last-run.json'
git log -1 --format='%H %an %s' -- flake.lock
```
Expected, if Sunday's update succeeded: the commit in `last-run.json` is the `github-actions[bot]` lock commit and `ranAt` is 2026-09-27. If the update failed (e.g. raider broke), there is no bot commit and the deployer skipping is correct — that is the out-of-scope raider problem, not this one.
