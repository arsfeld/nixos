#!/usr/bin/env bash
# Antigravity CLI compact statusline
# Displays: [agy]  branch* | model | context %
export GIT_OPTIONAL_LOCKS=0

input=$(cat)

# Extract fields in a single jq pass
tsv=$(echo "$input" | jq -r '[
  (.model.display_name // "Antigravity"),
  (.context_window.used_percentage // 0),
  (.workspace.current_dir // .cwd // ".")
] | @tsv')

IFS=$'\t' read -r model used_pct dir <<< "$tsv"

# Git branch and dirty state
git_dir="${dir:-.}"
branch_str=""
if git -C "$git_dir" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$git_dir" -c core.hooksPath=/dev/null symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$git_dir" -c core.hooksPath=/dev/null rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    [ -n "$(git -C "$git_dir" -c core.hooksPath=/dev/null status --porcelain 2>/dev/null)" ] && dirty="*"
    branch_str=" \033[35m ${branch}${dirty}\033[0m |"
  fi
fi

# Context usage color-coding
pct_int=${used_pct%.*}
if [ "${pct_int:-0}" -ge 85 ]; then
  ctx_color="\033[31m"  # Red
elif [ "${pct_int:-0}" -ge 60 ]; then
  ctx_color="\033[33m"  # Yellow
else
  ctx_color="\033[32m"  # Green
fi

pct_fmt=$(awk -v p="${used_pct:-0}" 'BEGIN { printf "%.1f", p }')

# Output formatted compact statusline
printf "\033[36m[agy]\033[0m%b \033[33m%s\033[0m | %b%s%% ctx\033[0m\n" \
  "$branch_str" "$model" "$ctx_color" "$pct_fmt"
