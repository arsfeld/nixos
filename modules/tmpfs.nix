# /tmp in RAM instead of on the root filesystem.
#
# On raider's btrfs root, scratch-heavy tools (flutter test's frontend_server
# wrote ~65 MB/s into /tmp) pushed IO pressure to ~34% "full"; every btrfs
# commit queued behind them, and the desktop stalled on /nix and / reads.
# Fedora, Arch, openSUSE and Debian 13 ship a tmpfs /tmp by default.
#
# Nix builds do not land here: Nix >= 2.30 builds in /nix/var/nix/builds
# (build-dir is unset), so the size cap only bounds ordinary scratch use.
# tmpfs pages can still go to swap under pressure. Raise the cap rather than
# dropping the feature if something legitimately needs more.
#
# Only for hosts with RAM to spare (16 GB and up). Mounting it on a running
# system hides what is already in /tmp, sockets included (X11, zellij), so
# the first activation is safest as `just boot <host>` and a reboot.
{
  flake.modules.nixos.tmpfs = {
    key = "modules/tmpfs";
    boot.tmp = {
      useTmpfs = true;
      tmpfsSize = "50%";
    };
  };
}
