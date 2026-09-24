# Weekly update → deploy handoff

## Problem

The weekly chain — GitHub `Weekly Update` refreshes `flake.lock`, galactica's
`weekly-deploy` rolls it out to tier-1 — has never completed end to end.

`update.yml`'s commit job pushes with the default `GITHUB_TOKEN`, and GitHub
does not start workflow runs for pushes made with that token. The bot's lock
commits therefore never get a `Build & Cache` run: `50b5580` (2026-08-23) and
`f338deb` (2026-09-20) have none, checked via `actions/runs?head_sha=`.
`weekly-deploy`'s gate (`hosts/galactica/weekly-deploy.nix`, the "Precondition"
block) looks for exactly that run, finds nothing, sends "skipped" and exits 0.
galactica's `last-run.json` still dates from 2026-09-13, when it deployed a
human commit; the 2026-09-20 run pulled `f338deb` and left no state.

Even the build `update.yml` runs itself can't stand in: it builds the pre-commit
SHA with an overridden lock, and `self` is in every system closure, so those
closures are not the committed commit's closures.

A timing problem sits behind the handoff. The "00:00 UTC" cron has started
between 01:15 and 03:56 UTC, the update run takes up to ~1.5 h (the 2026-09-20
commit landed 05:14 UTC), and a `Build & Cache` run takes 20–50 min. The deploy
timer fires at 06:00 UTC ± 10 min, so a fixed handoff would still usually find
the build in progress and skip.

## Design

### 1. `update.yml` dispatches the build

- Commit job permissions gain `actions: write` alongside `contents: write`.
- After `git push`, a new step runs `gh workflow run build.yml --ref master`
  with `GH_TOKEN: ${{ github.token }}`. `workflow_dispatch` is the documented
  exception to the `GITHUB_TOKEN` no-trigger rule.
- `--ref master` builds master's HEAD at dispatch time: the bot commit, or a
  human commit that raced in after it (which has its own push-triggered run
  anyway).
- The step is not `continue-on-error`: a failed dispatch fails the job, so the
  gap is red in CI rather than a silent skip on galactica.
- A comment on the step records why it exists (the `GITHUB_TOKEN` rule and the
  two commits it stranded).

The dispatched run is named "Build & Cache", has the bot commit as `head_sha`,
and uses bare `<host>` job names — exactly what the gate already matches. The
gate logic does not change.

### 2. `hosts/galactica/weekly-deploy.nix`

- `schedule` default: `Sun *-*-* 06:00:00 UTC` → `Sun *-*-* 12:00:00 UTC`.
- The option description states the actual constraint: cron start delay
  (up to ~4 h) + update run (~1.5 h) + dispatched build (20–50 min).
- The header comment's "the run that fires for master's new HEAD" becomes an
  accurate description: for bot commits that run is dispatched by `update.yml`.

### 3. Docs

`CLAUDE.md` "Weekly Automation": 06:00 → 12:00 UTC, plus one line that the bot's
push cannot trigger CI on its own, so `update.yml` dispatches `Build & Cache`.

## Rollout and verification

1. Commit and push; `just deploy galactica` from raider (a deployer change must
   be installed by hand — see CLAUDE.md).
2. `gh workflow run update.yml`. If inputs moved since `0d8213c`, confirm a
   `workflow_dispatch` `Build & Cache` run appears for the bot commit and goes
   green; once it has, `sudo systemctl start weekly-deploy` on galactica and
   confirm `last-run.json` names the bot commit.
3. If nothing changed upstream, no commit is made and the dispatch step never
   runs; the first real test is the next Sunday. Check Monday: `last-run.json`
   on galactica should name that Sunday's bot commit.

## Out of scope

- raider (nixos-unstable + Chaotic-Nyx) failing the tier-1 gate most weeks.
- The 2026-08-30 push rejection; `git pull --rebase` already exists.
- Replacing `GITHUB_TOKEN` with a PAT or GitHub App token (rejected: a
  long-lived repo-write credential to manage, and it does not fix the timing).
- Making the deployer poll for an in-progress build (rejected: a later fixed
  schedule is simpler, and a buggy deployer cannot deploy its own fix).
