# Claude Code Session Launcher Design

## Problem

Start a new, remote-controllable Claude Code session in any project on raider or on the
work MacBook (`mbp-idr`) from the Claude app or claude.ai, without being at that machine.

Remote control itself already works on both machines. `remoteControlAtStartup` is `true`
in raider's `~/.claude/settings.json`, and the account's session list holds `raider-*` and
`mbp-idr-local-*` Remote Control sessions. What is missing is the *launch*: today a
session only exists if someone started `claude` at the machine (`cc`, a terminal,
`claude agents`).

## Constraints that shaped the design

Checked against the Remote Control docs (code.claude.com/docs/en/remote-control) and
Claude Code 2.1.268 on raider:

- **A `claude remote-control` server is bound to one directory.** It accepts extra
  on-demand sessions (`--spawn same-dir|worktree`, `--capacity`), but only in its own
  working directory. Nothing in the app picks a folder.
- **Remote Control is outbound HTTPS only.** Neither machine has to reach the other, so the
  Mac's userspace-Tailscale SOCKS setup is irrelevant to this design.
- **`claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` cannot create Remote Control
  sessions.** An unattended service must use the normal `/login` credentials.
- **`DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and
  `DISABLE_GROWTHBOOK` each disable Remote Control.**
- **A global flag placed before `remote-control` is not carried to the sessions the server
  creates.** `--model` is accepted there and then ignored, so the launcher's model has to
  come from settings.
- **Server mode exits after roughly 10 minutes without network.** Interactive sessions
  retry indefinitely.
- **There is no CLI for workspace trust**, and the trust dialog is not forwarded to the app.
- **On raider, `claude` is a `nix run github:numtide/llm-agents.nix#claude-code` wrapper**
  (from `llmAgentScripts` in `home/home.nix`), so it floats to the latest release and
  needs `nix` and network to start.

Rejected alternatives:

- **One always-on server per pinned project.** One tap, but only covers listed projects and
  costs roughly 250–500 MB per server, which is what raider's current Claude processes use.
- **Dispatch.** Needs the Desktop app, which does not run on Linux.
- **Self-hosted environments.** Team/Enterprise only, and they run on fresh GitHub clones
  rather than local checkouts.
- **A custom launcher web page.** It would need an agent on each machine, and the user wants
  to launch from the Claude app.

## Design

A launcher session on each machine. You open **`launcher@raider`** or
**`launcher@mbp-idr`** in the Code tab and send `reel: fix the flaky test`. The launcher
runs `claude-spawn reel fix the flaky test`, which starts a new Remote Control session
**`reel@raider`** in `~/Code/reel` with that task as its first prompt. The new session
appears in the Code tab.

### `claude-spawn`

One portable bash script (Linux and macOS, branching on `uname` only where it must). It
is the whole mechanism; everything else is plumbing to call it.

- `claude-spawn <project> [task…]` resolves `<project>` in this order and stops at the
  first hit:
  1. a literal path (absolute or `~`-relative);
  2. an exact directory name directly under a configured root;
  3. `zoxide query <project>`;
  4. a case-insensitive substring match on directory names directly under the roots.

  If step 4 matches more than one directory, the script prints the candidates and exits 2.
  If nothing matches, it exits 3. The launcher turns both into a question back to you.
- `claude-spawn --list [filter]` prints the top candidates: zoxide's frecency list merged
  with the directories directly under the roots, filtered, capped at 20. Each is marked if
  it would fail the trust check.
- `claude-spawn --dry-run …` prints the resolved directory and the exact command, without
  running anything.
- **Session name** is `<basename>@<host>`, where `<host>` comes from `CLAUDE_SPAWN_HOST`
  (set by the service) or else `hostname -s`.
- **Trust check:** before starting anything, the script reads `~/.claude.json` with `jq`
  and never writes it. If the target directory is untrusted, it exits 4 with "open it once
  locally". Whether a trusted parent (raider's `~/Code` is trusted) makes a child trusted
  is spike 3; the check mirrors whatever the spike finds. The script never edits
  `~/.claude.json`: Claude rewrites that file constantly, and a concurrent edit would race
  with it.
- **Start:** `cd <dir> && claude --bg --remote-control <name> [task]`. If spike 1 shows
  that background sessions do not connect to Remote Control, it falls back to
  `claude --bg --exec 'claude --remote-control <name> [task]'`, an interactive
  Remote Control session running under the daemon's PTY. Either way the session is
  listed in `claude agents` and attachable with `claude attach`, and no tmux is needed.
- **Independence from the launcher:** on Linux the start command runs under
  `systemd-run --user --scope --collect`. The Claude daemon is started by whichever
  `claude --bg` call comes first; if that is a spawn, the daemon and every session it hosts
  would otherwise sit in the launcher unit's cgroup and die with it on the next restart.
  On macOS, `AbandonProcessGroup` in the launchd agent covers the same case.
- The spawned session's permission mode is not overridden, so it gets the user's default
  (`auto` on raider).

### Launcher workspace

A home-manager-managed directory, `~/.local/share/claude-launcher/`, containing:

- `CLAUDE.md`: "You launch Claude Code sessions on this machine. Each message names a
  project and optionally a task. Run `claude-spawn`, relay the result in one line, and ask
  which project was meant when it lists candidates. Do nothing else."
- `.claude/settings.json`, which sets:
  - `model: haiku`;
  - `permissions.defaultMode: dontAsk`, with `allow: ["Bash(claude-spawn:*)"]`, so every
    other tool call is denied;
  - hooks disabled and user plugins disabled, so hook-injected context such as superpowers'
    SessionStart hook does not reach the launcher. Spike 4 confirms that project-level
    settings are enough to achieve this.

### Service

Runs `claude remote-control --name launcher@<host>` in the launcher workspace, with the
default `--spawn same-dir`. That gives one pre-created launcher session, and `/clear`, which
works from the app, resets its context. The environment is set explicitly:

- `PATH` with `claude`, `zoxide`, `jq`, `git` and (raider) `nix`;
- `CLAUDE_SPAWN_HOST`;
- `CLAUDE_SPAWN_ROOTS`, colon-separated.

It carries none of the Remote-Control-disabling variables and no token.

- **raider:** a `systemd.user.services.claude-launcher` with `Restart=always`,
  `RestartSec=30`. If spike 2 shows `claude remote-control` needs a TTY, `ExecStart` wraps
  it in `script -qfc`. Observed while researching this design: `claude remote-control
  --help` run without a TTY printed the help and then kept running until it was killed.
- **Mac:** a `launchd.agents.claude-launcher` with `KeepAlive`, `AbandonProcessGroup`,
  `WorkingDirectory`, `EnvironmentVariables`, and logs to
  `~/Library/Logs/claude-launcher.log`. If the work network needs `HTTPS_PROXY` to reach
  the internet, it is set here, since launchd does not inherit the shell environment.

### Repository layout: two copies, on purpose

The two home-manager repositories stay independent: no flake input between them. That is
the user's explicit decision, and it overrides the usual preference for a single shared
module.

- **This repo:**
  - `home/scripts/claude-spawn`, following the existing `home/scripts/` + `writeScriptBin`
    convention;
  - `home/claude-launcher.nix`, the module (options, launcher workspace files, systemd
    unit), imported from `home/home.nix` and off by default;
  - raider enables it from its host config, following the per-host
    `home-manager.users.arosenfeld` pattern in `hosts/raider/fontconfig.nix`.
- **`arsfeld/idr-home`** (the live Mac config; `isdr-home` is a 2024 devcontainer config
  and is not involved):
  - a verbatim copy of `claude-spawn`;
  - its own module holding only the launchd side, configured with the Mac's roots (at least
    `~/dev-env/www`) and the path of the Mac's `claude`, which `idr-home` does not
    install.

`claude-spawn` is kept byte-identical in both repos, so a fix is a file copy. The modules
are not shared; each holds only its own platform's service.

Module options, same names in both copies:

| Option | Default |
| --- | --- |
| `enable` | `false` |
| `hostLabel` | the hostname |
| `roots` | `[]` |
| `claudeCommand` | `"claude"`, resolved from `PATH` |
| `extraPath` | `[]` |

## Failure handling

- **Network outage:** the server exits after ~10 minutes and the service manager restarts
  it. Spawned sessions retry on their own.
- **Machine asleep:** a closed Mac lid shows the launcher and its sessions offline, and they
  reconnect on wake (documented behaviour). A powered-off raider is out of scope.
- **Claude updates:** on raider the wrapper floats, so the launcher picks up a new release
  whenever it restarts, and spawned sessions keep the version the daemon started with
  (`claude respawn --all` moves them). On the Mac, the native updater applies on the next
  restart.
- **Ambiguous, unknown or untrusted project:** exit codes 2/3/4. The launcher asks, and
  nothing starts.
- **Hostile task text:** the task only ever reaches `claude-spawn` as arguments. Claude Code
  checks each part of a compound command against the allow rule, so `x; rm -rf ~` is
  denied under `dontAsk`.
- **Auth expiry:** the launcher fails the same way an interactive session would, and the fix
  is the same: `/login` at the machine.

## Spikes before implementation

Each spike picks a branch of the design above. All four run on raider.

1. **Does `claude --bg --remote-control <name>` appear in the Code tab?** Yes: use it.
   No: use the `--exec` fallback.
2. **Does `claude remote-control` run without a TTY under systemd?** No: wrap `ExecStart`
   in `script -qfc`.
3. **Is a never-opened project under trusted `~/Code` (e.g. `~/Code/arban`) trusted without
   a dialog?** This decides whether the trust check walks up to parent directories.
4. **Do the launcher's project settings keep user hooks and plugins out of its sessions?**
   If not, find the narrowest setting that does before shipping.

## Verification

- **`claude-spawn --dry-run`** against a temporary tree of roots and a fake zoxide, covering
  an exact match, an ambiguous match (exit 2), no match (exit 3) and an untrusted directory
  (exit 4).
- **`just build raider`**, then `just deploy raider`.
- **End to end, from the phone:** open `launcher@raider`, send `nixos`. `nixos@raider`
  appears in the Code tab and answers a message.
- **Survival:** `systemctl --user restart claude-launcher`; the spawned session stays
  online.
- **Ambiguity:** send a query that matches several projects. The launcher lists them and
  starts nothing.
- **Mac:** the same end-to-end and restart checks, after the `idr-home` switch.

## Out of scope

- Launching on one machine from the other machine's launcher.
- Waking a powered-off raider.
- Pinned always-on per-project servers. They can be added later without changing anything
  here.
