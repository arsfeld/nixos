# /tmp in RAM instead of on the root btrfs.
#
# On btrfs, scratch-heavy tools (flutter test's frontend_server wrote ~65 MB/s
# into /tmp) pushed IO pressure to ~34% "full" on the root disk; every btrfs
# commit queued behind them, and the desktop stalled on /nix and / reads.
#
# Nix builds do not land here: Nix >= 2.30 builds in /nix/var/nix/builds
# (build-dir is unset), so the size cap only bounds ordinary scratch use.
# tmpfs pages can still go to swap under pressure. Raise the cap rather than
# reverting if something legitimately needs more.
{
  configurations.nixos.raider.module = {
    boot.tmp = {
      useTmpfs = true;
      tmpfsSize = "50%";
    };
  };
}
