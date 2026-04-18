#!/usr/bin/env bash
# Claude Code status line - faithfully mirrors oh-my-posh config.json theme
# Palette: yellow=#F3AE35 orange=#F07623 green=#59C9A5 blue=#4B95E9
#          black=#262B44  white=#E0DEF4  red=#D81E5B

input=$(cat)

cwd=$(echo "$input"     | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input"   | jq -r '.model.display_name // empty')
ctx_rem=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# ── palette (24-bit fg / bg helpers) ────────────────────────────────────────
fg()  { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
bg()  { printf '\033[48;2;%d;%d;%dm' "$1" "$2" "$3"; }
reset=$'\033[0m'

# named colours  r    g    b
c_yellow() { echo "243 174  53"; }   # #F3AE35
c_orange()  { echo "240 118  35"; }  # #F07623
c_green()   { echo " 89 201 165"; }  # #59C9A5
c_blue()    { echo " 75 149 233"; }  # #4B95E9
c_black()   { echo " 38  43  68"; }  # #262B44
c_white()   { echo "224 222 244"; }  # #E0DEF4
c_red()     { echo "216  30  91"; }  # #D81E5B

FG_YELLOW=$(fg $(c_yellow)); BG_YELLOW=$(bg $(c_yellow))
FG_ORANGE=$(fg $(c_orange)); BG_ORANGE=$(bg $(c_orange))
FG_GREEN=$(fg $(c_green));   BG_GREEN=$(bg $(c_green))
FG_BLUE=$(fg $(c_blue));     BG_BLUE=$(bg $(c_blue))
FG_BLACK=$(fg $(c_black))
FG_WHITE=$(fg $(c_white))
FG_RED=$(fg $(c_red));       BG_RED=$(bg $(c_red))

# powerline / nerd-font glyphs used by the theme
# Use explicit Unicode escapes so the bytes are always correct regardless of
# how the script file is saved or re-encoded.
PL_RIGHT=$'\uE0B0'   # U+E0B0  solid right-pointing powerline triangle
DIAMOND_L=$'\uE0B6'  # U+E0B6  left  half-circle cap (session leading cap)
DIAMOND_R=$'\uE0B4'  # U+E0B4  right half-circle cap (status trailing cap)

# ── segment 1: session (hostname) ───────────────────────────────────────────
# diamond style: yellow bg, black fg
# leading_diamond=U+E0B6 (fg=yellow on transparent) → content → connector emitted at seg 2 start
host=$(hostname -s)
printf "%s%s%s%s %s " \
  "$FG_YELLOW" "$DIAMOND_L" \
  "$BG_YELLOW" "$FG_BLACK" \
  "$host"

# ── segment 2: path ─────────────────────────────────────────────────────────
# powerline style: orange bg, white fg, leading powerline symbol (prev_bg=yellow → orange)
dir="${cwd:-$(pwd)}"
dir="${dir/#$HOME/~}"
# agnoster style: collapse middle dirs to first letter
if [[ "$dir" == "~"* ]]; then
  rest="${dir:1}"   # strip leading ~
  prefix="~"
else
  rest="$dir"
  prefix=""
fi
IFS='/' read -ra parts <<< "$rest"
count=${#parts[@]}
if [ "$count" -gt 3 ]; then
  short_parts=()
  for (( i=0; i < count-1; i++ )); do
    p="${parts[$i]}"
    if [ -n "$p" ]; then
      short_parts+=("${p:0:1}")
    fi
  done
  short_parts+=("${parts[$((count-1))]}")
  dir="${prefix}/$(IFS='/'; echo "${short_parts[*]}")"
  dir="${dir//\/\//\/}"
fi

printf "%s%s%s%s  %s " \
  "$BG_ORANGE" "$FG_YELLOW" "$PL_RIGHT" \
  "$FG_WHITE" \
  "$dir"

# ── segment 3: git ──────────────────────────────────────────────────────────
# powerline style: green bg (yellow if dirty), black fg
git_dir="${cwd:-$(pwd)}"
if git -C "$git_dir" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$git_dir" -c core.hooksPath=/dev/null symbolic-ref --short HEAD 2>/dev/null \
           || git -C "$git_dir" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    porcelain=$(git -C "$git_dir" -c core.hooksPath=/dev/null status --porcelain 2>/dev/null)
    dirty=""
    if [ -n "$porcelain" ]; then
      dirty=" ~"
    fi
    # dirty → yellow bg, clean → green bg
    if [ -n "$dirty" ]; then
      GIT_BG=$BG_YELLOW; GIT_FG_PL=$FG_YELLOW
    else
      GIT_BG=$BG_GREEN;  GIT_FG_PL=$FG_GREEN
    fi
    printf "%s%s%s%s  %s%s " \
      "$GIT_BG" "$FG_ORANGE" "$PL_RIGHT" \
      "$FG_BLACK" \
      "$branch" "$dirty"
    PREV_WAS_GIT=1
    LAST_GIT_FG=$GIT_FG_PL
  else
    PREV_WAS_GIT=0
    LAST_GIT_FG=$FG_ORANGE
  fi
else
  PREV_WAS_GIT=0
  LAST_GIT_FG=$FG_ORANGE
fi

# ── segment 4: status / end cap ─────────────────────────────────────────────
# diamond style: blue bg, white fg
# leading_diamond uses transparent→blue: we emit the prev-colour → blue PL then the trailing diamond
if [ "${PREV_WAS_GIT:-0}" -eq 1 ]; then
  PREV_FG=$LAST_GIT_FG
else
  PREV_FG=$FG_ORANGE
fi
# connector (prev_bg→blue), content (white on blue), trailing cap (blue fg on transparent)
printf "%s%s%s%s %s%s%s" \
  "$BG_BLUE" "$PREV_FG" "$PL_RIGHT" \
  "$FG_WHITE" \
  $'\033[0m' "$FG_BLUE" "$DIAMOND_R"

# Explicitly clear bg to terminal default before right-side plain text.
# Use \033[49m (default background) so the model/ctx text has no bg colour.
printf $'\033[0m\033[49m'

# ── right-side info (model + context) in theme's right-block style ──────────
# right block: plain transparent style — only fg colour codes, no bg codes.
right_parts=()
if [ -n "$model" ]; then
  right_parts+=("${FG_WHITE}model ${FG_BLUE}${model}")
fi
if [ -n "$ctx_rem" ]; then
  ctx_int=${ctx_rem%.*}   # strip decimal if any
  right_parts+=("${FG_WHITE}ctx ${FG_BLUE}${ctx_int}%")
fi
if [ ${#right_parts[@]} -gt 0 ]; then
  printf "  "
  for (( i=0; i<${#right_parts[@]}; i++ )); do
    [ $i -gt 0 ] && printf "${FG_WHITE} · "
    printf "%s" "${right_parts[$i]}"
  done
  printf $'\033[0m\033[49m'
fi
