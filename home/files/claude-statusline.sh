#!/usr/bin/env bash
# Claude Code status line - mirrors the oh-my-posh theme (oh-my-posh.omp.json),
# which follows Starship's Pastel Powerline preset: one powerline bar,
# segments joined by U+E0B0 separators, rounded caps at both ends.

# Never take optional git locks: `git status` otherwise grabs .git/index.lock
# to refresh cached stat info. With many concurrent Claude sessions re-rendering
# (and killing) this statusline, interrupted status calls leave stale index.lock
# files scattered across repos. This makes every git invocation here lock-free.
export GIT_OPTIONAL_LOCKS=0

input=$(cat)

cwd=$(echo "$input"     | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input"   | jq -r '.model.display_name // empty')
ctx_rem=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# ── palette (same names and values as the oh-my-posh palette) ───────────────
purple="154 52 142"   # #9A348E
pink="218 98 125"     # #DA627D
peach="252 161 125"   # #FCA17D
sky="134 187 216"     # #86BBD8
navy="51 101 138"     # #33658A
red="216 30 91"       # #D81E5B
text="224 222 244"    # #E0DEF4
dark="46 52 64"       # #2E3440

fg() { printf '\033[38;2;%d;%d;%dm' $1; }
bg() { printf '\033[48;2;%d;%d;%dm' $1; }
reset=$'\033[0m'

# Explicit escapes so the glyph bytes survive any re-encoding of this file.
SEP=$''     # solid right-pointing powerline triangle
CAP_L=$''   # left half-circle cap
CAP_R=$''   # right half-circle cap

# seg <bg> <fg> <content>: open the bar with a cap, or join it to the
# previous segment with a separator drawn in the previous background colour.
prev=""
seg() {
  if [ -z "$prev" ]; then
    printf '%s%s' "$(fg "$1")" "$CAP_L"
  else
    printf '%s%s%s' "$(bg "$1")" "$(fg "$prev")" "$SEP"
  fi
  printf '%s%s %s ' "$(bg "$1")" "$(fg "$2")" "$3"
  prev=$1
}

# ── host ─────────────────────────────────────────────────────────────────────
seg "$purple" "$text" "$(hostname -s)"

# ── path (agnoster: collapse middle dirs to their first letter) ─────────────
dir="${cwd:-$(pwd)}"
dir="${dir/#$HOME/~}"
if [[ "$dir" == "~"* ]]; then
  rest="${dir:1}"; prefix="~"
else
  rest="$dir"; prefix=""
fi
IFS='/' read -ra parts <<< "$rest"
count=${#parts[@]}
if [ "$count" -gt 3 ]; then
  short_parts=()
  for (( i=0; i < count-1; i++ )); do
    p="${parts[$i]}"
    [ -n "$p" ] && short_parts+=("${p:0:1}")
  done
  short_parts+=("${parts[$((count-1))]}")
  dir="${prefix}/$(IFS='/'; echo "${short_parts[*]}")"
  dir="${dir//\/\//\/}"
fi
seg "$pink" "$text" $''" $dir"

# ── git ──────────────────────────────────────────────────────────────────────
git_dir="${cwd:-$(pwd)}"
if git -C "$git_dir" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$git_dir" -c core.hooksPath=/dev/null symbolic-ref --short HEAD 2>/dev/null \
           || git -C "$git_dir" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    [ -n "$(git -C "$git_dir" -c core.hooksPath=/dev/null status --porcelain 2>/dev/null)" ] && dirty=" ~"
    seg "$peach" "$dark" $''" $branch$dirty"
  fi
fi

# ── model ────────────────────────────────────────────────────────────────────
[ -n "$model" ] && seg "$sky" "$dark" "$model"

# ── context remaining (red when nearly full) ────────────────────────────────
if [ -n "$ctx_rem" ]; then
  ctx_int=${ctx_rem%.*}
  ctx_bg=$navy
  [ "$ctx_int" -lt 20 ] 2>/dev/null && ctx_bg=$red
  seg "$ctx_bg" "$text" "ctx ${ctx_int}%"
fi

# ── close the bar ───────────────────────────────────────────────────────────
printf '%s%s%s%s' "$reset" "$(fg "$prev")" "$CAP_R" "$reset"
