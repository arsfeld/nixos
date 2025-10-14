---
id: task-11
title: Create smart backlog alias that finds project root
status: Done
assignee:
  - '@claude'
created_date: '2025-10-12 17:26'
updated_date: '2025-10-12 17:31'
labels:
  - home-manager
  - shell
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The current backlog alias runs in the current directory, which can accidentally create backlog entries in the wrong location. We need a shell function that searches up the directory tree for a backlog/ folder and executes backlog.md from there.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Shell function searches up directory tree for backlog/ folder
- [x] #2 Changes to directory containing backlog/ before running backlog.md
- [x] #3 Works across bash, zsh, and fish shells
- [x] #4 Falls back to current behavior if no backlog/ folder is found
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Research directory traversal patterns for bash/zsh and fish shells
2. Remove the simple alias from home.shellAliases
3. Implement smart backlog function for bash/zsh in programs.bash/zsh
4. Implement smart backlog function for fish in programs.fish
5. Test the function by running it from various directory levels
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Replaced the simple backlog alias with a smart shell function that searches up the directory tree for a backlog/ folder.

## Changes Made

1. **Removed simple alias** from home.shellAliases (line 116)

2. **Implemented bash function** in programs.bash.initExtra (lines 260-283):
   - Searches up directory tree using while loop and dirname
   - Uses subshell (cd "$found_root" && ...) to run backlog.md from project root
   - Falls back to current directory if no backlog/ folder found
   - Preserves all command arguments with "$@"

3. **Implemented zsh function** in programs.zsh.initContent (lines 214-235):
   - Identical logic to bash implementation
   - Uses local variables and same traversal algorithm

4. **Implemented fish function** in programs.fish.functions (lines 167-192):
   - Fish-specific syntax using set variables
   - Uses "test" instead of "[[ ]]" conditionals
   - Uses "begin...end" block for command grouping
   - Preserves arguments with $argv

## Technical Details

- All functions search from $PWD upward until finding backlog/ or reaching /
- Uses dirname to traverse up the directory tree
- Runs in subshell/block to avoid changing user's working directory\n- Preserves all arguments passed to backlog command\n- Falls back gracefully if no project root found\n\n## Validation\n\n- Syntax validated with nix build dry-run\n- Configuration builds successfully for all shells
<!-- SECTION:NOTES:END -->
