# Stop devenv process trees left behind in Claude Code worktrees.
#
# Agent sessions in ~/Code/mydia each get a .claude/worktrees/<name> checkout and
# start its devenv there: a Phoenix server, a Flutter build_runner watcher
# (~1.5 GB apiece) and Postgres. Nothing stopped them when the session ended, so
# ten of them piled up into 27 GB of swap, half of it in the swapfile on the
# games disk, and games froze on I/O. mydia's SessionEnd hook now stops a
# worktree's devenv on a clean exit; this timer is the backstop for crashed
# sessions, deleted worktrees and the hook's own failures.
#
# A worktree's devenv is stale when its directory is gone, or when no Claude
# transcript for it (~/.claude/projects/<path with every non-alphanumeric
# turned into "-">/*.jsonl) has been written for `idleMinutes`. Liveness has to
# come from the transcript: remote-control sessions run inside the long-lived
# claude-rc-* process, whose cwd is the main checkout, so there is no
# per-worktree process to look for. Only processes under a .claude/worktrees/
# path are touched, never a main checkout's.
{pkgs, ...}: let
  idleMinutes = 120;

  reaper = pkgs.writeShellApplication {
    name = "devenv-reaper";
    runtimeInputs = [pkgs.procps pkgs.coreutils pkgs.findutils];
    text = ''
      now=$(date +%s)
      idle=$((${toString idleMinutes} * 60))
      snap=$(ps -eo pid=,ppid=,etimes=,args=)

      declare -A children wt_roots wt_age
      while read -r pid ppid etimes args; do
        children[$ppid]+=" $pid"
        # devenv's own signatures, as in mydia's `./dev killall`: the process
        # manager, its per-process wrapper scripts and the Postgres data dir.
        case "$args" in
          *daemon-processes*|*devenv-processes*|*.devenv/state/postgres*) ;;
          *) continue ;;
        esac
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
        cwd=''${cwd% (deleted)}
        [[ "$cwd" =~ ^(.*/\.claude/worktrees/[^/]+) ]] || continue
        wt="''${BASH_REMATCH[1]}"
        wt_roots[$wt]+=" $pid"
        if [ "''${wt_age[$wt]:-0}" -lt "$etimes" ]; then wt_age[$wt]=$etimes; fi
      done <<< "$snap"

      for wt in "''${!wt_roots[@]}"; do
        if [ -d "$wt" ]; then
          transcripts="$HOME/.claude/projects/''${wt//[^A-Za-z0-9]/-}"
          last=$(find "$transcripts" -maxdepth 1 -name '*.jsonl' -printf '%T@\n' 2>/dev/null \
            | sort -n | tail -n1)
          last=''${last%.*}
          # No transcript at all: fall back to how long the devenv has run.
          [ -n "$last" ] || last=$((now - wt_age[$wt]))
          [ $((now - last)) -ge "$idle" ] || continue
          why="idle $(((now - last) / 60))m"
        else
          why="worktree deleted"
        fi

        pids=""
        read -ra stack <<< "''${wt_roots[$wt]}"
        while [ ''${#stack[@]} -gt 0 ]; do
          p=''${stack[0]}
          stack=("''${stack[@]:1}")
          pids="$pids $p"
          # shellcheck disable=SC2206
          stack+=(''${children[$p]:-})
        done
        # shellcheck disable=SC2086
        pids=$(printf '%s\n' $pids | sort -un | tr '\n' ' ')

        echo "stopping $(wc -w <<< "$pids") process(es) in $wt ($why)"
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
        sleep 5
        for p in $pids; do
          kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
        done
        true
      done
    '';
  };
in {
  systemd.user.services.devenv-reaper = {
    description = "Stop devenv processes in stale Claude Code worktrees";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${reaper}/bin/devenv-reaper";
    };
  };

  systemd.user.timers.devenv-reaper = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "15min";
    };
  };
}
