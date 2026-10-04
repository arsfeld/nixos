# htop layout modernization

## Problem

htop's header lost its right column, which held cores 8–15, Tasks, Load average and Uptime.
`home/files/htoprc` declares four meters in `column_meters_1`
(`RightCPUs2 Tasks LoadAverage Uptime`) but only three modes in
`column_meter_modes_1`. htop 3.5 discards a header column whose meter and mode
counts differ, and htop 3.2, which the file was written for, did not. The
file also has no trailing newline. The surviving left column split its width
between two CPU columns, which is why the CPU bars looked tight.

## Approach

Replace the static `home/files/htoprc` and its `xdg.configFile."htop/htoprc"`
entry in `home/home.nix` with home-manager's `programs.htop`. Its
`config.lib.htop` helpers (`leftMeters`/`rightMeters` with `bar`/`text`, and
`fields`) declare each meter together with its mode, so the counts cannot
drift apart again, and the file no longer pins a `htop_version`.

Check during implementation: HM writes flat `key=value` lines. If it cannot
emit the `screen:<name>=…` lines and their `.key=value` continuation lines in
order, drop the explicit screens, let htop derive Main from `fields`, and add
the I/O screen back by appending raw text to the generated file. Decide this by
inspecting the generated file and rendering it, not by assumption.

## Header

`header_layout = two_67_33`.

- Left (2/3): `AllCPUs2` (bar), `Memory` (bar), `Swap` (bar).
- Right (1/3), all text: `Hostname`, `Uptime`, `Tasks`, `LoadAverage`,
  `PressureStallCPUSome`, `PressureStallMemorySome`, `DiskIO`, `NetworkIO`.

On 16-core hosts (raider, galactica) the header is 10 rows. On 4-core hosts
(basestar, pegasus) the 8-row sidebar sets the height. All hosts share the
same config.

## Process list

- Main screen: `PID USER M_RESIDENT M_SHARE STATE PERCENT_CPU PERCENT_MEM TIME
  CCGROUP Command`, sorted by `PERCENT_CPU` descending. `PRIORITY`, `NICE` and
  `M_VIRT` are removed. `CCGROUP` shows the systemd unit or podman container.
- I/O screen: unchanged (`PID USER COMM IO_PRIORITY IO_RATE IO_READ_RATE
  IO_WRITE_RATE`, sorted by `IO_RATE`).
- Highlighting: `highlight_base_name=1`, `show_program_path=1`,
  `shadow_distribution_path_prefix=1` (dims `/nix/store/…`), and
  `highlight_changes=1` (colors new and exiting processes).
- Unchanged: mouse on, `delay=15`, kernel and userland threads hidden,
  `show_cpu_usage=1`, color scheme 0.

## Testing

1. Build raider's configuration.
2. Render htop headless in tmux at 80, 120 and 200 columns with `HTOPRC`
   pointed at a writable copy of the generated file. Confirm that both header
   columns render, that all 16 CPUs and every sidebar meter appear, and that
   the Main screen shows the CGROUP column and both tabs.
3. Run `just fmt`, then deploy raider.
