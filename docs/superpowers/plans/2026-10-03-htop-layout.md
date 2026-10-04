# htop Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore htop's missing right header column and adopt the new layout from `docs/superpowers/specs/2026-10-03-htop-layout-design.md`.

**Architecture:** Replace the static `home/files/htoprc` with home-manager's `programs.htop.settings` in `home/home.nix`. HM's `leftMeters`/`rightMeters` helpers pair each meter with its mode. That mismatch, 4 meters against 3 modes, is what made htop 3.5 drop the right column. A headless tmux render check is the test.

**Tech Stack:** Nix, home-manager `programs.htop`, htop 3.5.3, tmux (for the render check).

## Global Constraints

- Commit straight to `master`. No branches, no worktrees.
- Commit only the files this plan touches. The working tree has unrelated changes (`hosts/raider/configuration.nix`, `packages/claude-desktop/default.nix`), and you must leave them unstaged and uncommitted. Use `git commit -- <paths>`.
- Conventional commits, scope `home`. Never mention Claude.
- `header_layout = two_67_33`. Left: `AllCPUs2`, `Memory`, `Swap` (bar). Right (text): `Hostname`, `Uptime`, `Tasks`, `LoadAverage`, `PressureStallCPUSome`, `PressureStallMemorySome`, `DiskIO`, `NetworkIO`.
- Main fields: `PID USER M_RESIDENT M_SHARE STATE PERCENT_CPU PERCENT_MEM TIME COMM`, `sort_key = PERCENT_CPU`, `sort_direction = -1`.
- Third tab: `screen:Units=PID USER PERCENT_CPU PERCENT_MEM CCGROUP Command`. No other `screen:` lines. htop 3.5 builds Main and I/O itself.
- Run the render check on raider, because it asserts CPU ` 15[` (16 cores).

---

### Task 1: Move htop config into `programs.htop`

**Files:**
- Modify: `home/home.nix` (line 150 `htop` in `home.packages`, lines 253–255 `xdg.configFile."htop/htoprc"`)
- Delete: `home/files/htoprc`
- Test: `/tmp/claude-1000/-home-arosenfeld-Code-nixos/c3714979-ace7-41fe-b7ac-dfeec2e605b9/scratchpad/htop-check.sh` (scratch, not committed)

**Interfaces:**
- Consumes: `config.lib.htop.{fields,leftMeters,rightMeters,bar,text}` from home-manager's `programs.htop` module. These exist only once `programs.htop.enable = true`.
- Produces: the generated rc at `nixosConfigurations.raider.config.home-manager.users.arosenfeld.xdg.configFile.htop.source`, a directory containing `htoprc`.

- [ ] **Step 1: Write the render check (the test)**

Create `$SCRATCH/htop-check.sh`, where `SCRATCH=/tmp/claude-1000/-home-arosenfeld-Code-nixos/c3714979-ace7-41fe-b7ac-dfeec2e605b9/scratchpad` (it may already exist with this exact content):

```bash
#!/usr/bin/env bash
# Usage: htop-check.sh <htoprc>   — renders htop headless and asserts the layout.
set -u
rc_src=$1; work=$(mktemp -d); fail=0
cp "$rc_src" "$work/rc"; chmod u+w "$work/rc"
grab() { # width -> header+list capture; $2 = number of Tab presses first
  tmux -L htc kill-server 2>/dev/null
  tmux -L htc new-session -d -x "$1" -y 24 "HTOPRC=$work/rc htop"
  sleep 3
  for _ in $(seq 1 "${2:-0}"); do tmux -L htc send-keys Tab; sleep 1.5; done
  tmux -L htc capture-pane -p; tmux -L htc kill-server
}
need() { grep -qF -- "$2" <<<"$1" || { echo "FAIL [$3]: missing '$2'"; fail=1; }; }
for w in 80 120 200; do
  out=$(grab "$w")
  for s in "Hostname:" "Uptime:" "Tasks:" "Load average:" "PSI some CPU" "PSI some memory" "Dsk:" "Net:" "Mem[" "Swp[" " 15[" "[Main] [I/O] [Units]" "Command"; do
    need "$out" "$s" "w=$w main"
  done
  grep -q " PRI " <<<"$out" && { echo "FAIL [w=$w]: PRI column still present"; fail=1; }
done
units=$(grab 120 2)
need "$units" "CGROUP" "units tab"
[ $fail = 0 ] && echo PASS || { echo "--- last capture (w=200):"; echo "$out"; }
rm -rf "$work"; exit $fail
```

`chmod +x "$SCRATCH/htop-check.sh"`

- [ ] **Step 2: Run it against the current file to verify it fails**

Run: `$SCRATCH/htop-check.sh home/files/htoprc`
Expected: FAIL lines, among them `missing 'Load average:'`, `missing ' 15['` and `missing 'CGROUP'`.

- [ ] **Step 3: Implement**

In `home/home.nix`, delete the `htop` line from `home.packages` (line 150), because `programs.htop` installs its own package. Then replace

```nix
  xdg.configFile."htop/htoprc" = {
    source = ./files/htoprc;
  };
```

with

```nix
  programs.htop = {
    enable = true;
    settings =
      {
        header_layout = "two_67_33";
        fields = with config.lib.htop.fields; [
          PID
          USER
          M_RESIDENT
          M_SHARE
          STATE
          PERCENT_CPU
          PERCENT_MEM
          TIME
          COMM
        ];
        sort_key = config.lib.htop.fields.PERCENT_CPU;
        sort_direction = -1;
        # CCGROUP sizes itself to the longest cgroup, which would push Command
        # off-screen in Main, so it gets its own tab. HM writes keys
        # alphabetically and cannot emit a screen's `.sort_key` line, so this
        # tab opens sorted by PID. Main and I/O are htop's built-in screens.
        "screen:Units" = "PID USER PERCENT_CPU PERCENT_MEM CCGROUP Command";
        screen_tabs = true;
        delay = 15;
        enable_mouse = true;
        color_scheme = 0;
        hide_kernel_threads = true;
        hide_userland_threads = true;
        show_cpu_usage = true;
        highlight_base_name = true;
        show_program_path = true;
        shadow_distribution_path_prefix = true;
        highlight_changes = true;
        highlight_megabytes = true;
        highlight_threads = true;
      }
      // (with config.lib.htop;
        leftMeters [
          (bar "AllCPUs2")
          (bar "Memory")
          (bar "Swap")
        ])
      // (with config.lib.htop;
        rightMeters [
          (text "Hostname")
          (text "Uptime")
          (text "Tasks")
          (text "LoadAverage")
          (text "PressureStallCPUSome")
          (text "PressureStallMemorySome")
          (text "DiskIO")
          (text "NetworkIO")
        ]);
  };
  # programs.htop links ~/.config/htop as a whole directory, but it is a real
  # directory today; link per file instead so activation never has to move it.
  xdg.configFile."htop".recursive = true;
```

Then: `git rm -q home/files/htoprc`

- [ ] **Step 4: Build the generated rc and inspect it**

Run:
```bash
nix build --no-link --print-out-paths .#nixosConfigurations.raider.config.home-manager.users.arosenfeld.xdg.configFile.htop.source
```
Then Read `<out>/htoprc`. Expected: `header_layout=two_67_33` is the first line, `left_meter_modes=1 1 1`, `right_meter_modes=2 2 2 2 2 2 2 2` (8 modes for 8 meters), `fields=0 48 39 40 2 46 47 49 1`, `sort_key=46`, `screen:Units=…`, and a trailing newline.

- [ ] **Step 5: Run the render check against the generated rc**

Run: `$SCRATCH/htop-check.sh <out>/htoprc`
Expected: `PASS`

- [ ] **Step 6: Build the full host, format, commit**

```bash
just fmt
nix build --no-link .#nixosConfigurations.raider.config.system.build.toplevel
git add home/home.nix
git commit -m "fix(home): rebuild htop layout via programs.htop" -- home/home.nix home/files/htoprc
git status --short   # the unrelated raider/claude-desktop changes must still be listed
```

### Task 2: Deploy to raider and verify the live config

**Files:** none

**Interfaces:**
- Consumes: the commit from Task 1.

- [ ] **Step 1: Deploy**

Run: `just deploy raider`
Expected: both phases succeed. Phase 1 pushes to niks3, and phase 2 activates locally through sudo.

Note: this activates the whole raider config, including the unrelated uncommitted edit in `hosts/raider/configuration.nix`, because flakes see the working tree. Mention that in the report.

- [ ] **Step 2: Verify the live file**

```bash
test -d ~/.config/htop -a ! -L ~/.config/htop && echo dir-ok   # still a real directory
readlink ~/.config/htop/htoprc          # → .../home-manager-files/.config/htop/htoprc
test ! -e ~/.config/htop.bak && echo no-backup
$SCRATCH/htop-check.sh ~/.config/htop/htoprc
```
Expected: `dir-ok`, the readlink path, `no-backup`, then `PASS`.
