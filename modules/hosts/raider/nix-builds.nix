# Nix builds: aarch64 binfmt emulation kept off the builder list, cores per job, memory reservations.
{
  configurations.nixos.raider.module = {lib, ...}: {
    boot = {
      binfmt.emulatedSystems = ["aarch64-linux"];
      binfmt.preferStaticEmulators = true;
    };

    # binfmt lets raider *run* aarch64 binaries, but NixOS also derives
    # nix.settings.extra-platforms from binfmt.emulatedSystems, which makes Nix
    # treat raider as a valid aarch64 builder. Nix prefers a free local slot
    # over a remote builder, and with max-jobs = 16 there almost always is one,
    # so aarch64 derivations get built here under qemu instead of natively on
    # basestar -- which then sits idle. Determinate Nix's functional test suite
    # ran >4h in checkPhase that way and blocked a whole tier-1 deploy.
    # Keep the emulator for running binaries; take aarch64 off the builder list
    # so it goes to basestar. i686-linux is the stock x86_64 default. See #405.
    nix.settings.extra-platforms = lib.mkForce ["i686-linux"];

    # The default cores = 0 gives every one of the 16 jobs all 16 CPUs (make
    # -j16 each), so a nixpkgs bump that rebuilds cylon-link's cross toolchain
    # and kernel alongside raider's own packages drove load past 110 and left
    # the desktop unusable. Four per job still saturates the machine when
    # several builds run, without the 16x oversubscription.
    nix.settings.cores = 4;

    # Builds pushed the desktop into swap: during that rebuild user.slice held
    # ~2 GiB in RAM against ~12 GiB swapped, and pages only come back on touch,
    # so every click faulted from disk long after the builds had freed memory.
    # Reserve some RAM for the session and make the daemon reclaim its own
    # memory first. MemoryHigh throttles rather than kills.
    systemd.slices.user = {
      overrideStrategy = "asDropin";
      sliceConfig.MemoryLow = "6G";
    };
    systemd.services.nix-daemon.serviceConfig.MemoryHigh = "20G";
  };
}
