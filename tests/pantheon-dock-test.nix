# Boots Pantheon with the patched dock (modules/constellation/pantheon-dock):
# two stacks, and the zoom pinned mid-dock through the DOCK_ZOOM_AT test hook,
# since pointer injection is unreliable. Checks that the dock comes up with
# both, and survives an invalid stacks value and an out-of-range zoom-size.
# Modelled on nixpkgs' nixos/tests/pantheon.nix, but with LightDM autologin
# instead of typing into the greeter.
# It runs on inputs.nixpkgs (stable), whereas raider's dock is built from unstable.
{pkgs, ...}: {
  name = "pantheon-dock";

  nodes.machine = {...}: {
    imports = [
      "${pkgs.path}/nixos/tests/common/user-account.nix"
      ../modules/constellation/pantheon-dock
    ];

    # Workaround ".gala-wrapped invoked oom-killer" (as upstream's test).
    virtualisation.memorySize = 2047;

    services.xserver.enable = true;
    services.desktopManager.pantheon.enable = true;
    services.displayManager = {
      defaultSession = "pantheon-wayland";
      autoLogin = {
        enable = true;
        user = "alice";
      };
    };

    constellation.desktop.pantheon.dockStacks = [
      {
        source = "~/Downloads";
        view = "fan";
        sort = "date-added";
      }
      {source = "applications";}
    ];

    systemd.tmpfiles.rules = ["d /home/alice/Downloads 0755 alice users -"];

    # The session's dock inherits this and zooms as if the pointer were over it.
    environment.sessionVariables.DOCK_ZOOM_AT = "1.5";
  };

  testScript = {nodes, ...}: let
    user = nodes.machine.users.users.alice;
    bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
    dock = "pgrep -f '(^|/)io\\.elementary\\.dock$'";
  in ''
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${toString user.uid}/wayland-0")

    with subtest("The patched dock starts with the configured stacks"):
        machine.wait_until_succeeds("${dock}")
        machine.succeed("su - alice -c '${bus} gsettings get io.elementary.dock stacks' | grep -q applications")
        machine.sleep(10)
        # Only subtest 2's positive match proves this negative check isn't vacuous:
        # it shows the same journal line is greppable when the dock does emit it.
        machine.fail("journalctl -b -t io.elementary.dock | grep 'Ignoring stack'")
        machine.screenshot("dock_stacks")
        dock_pid = machine.succeed("${dock}").strip()

    with subtest("An invalid stack is logged and skipped, and the dock stays up"):
        machine.succeed("su - alice -c \"${bus} gsettings set io.elementary.dock stacks \\\"[('~/Downloads', 'spiral', 'name', 'stack')]\\\"\"")
        machine.wait_until_succeeds("journalctl -b -t io.elementary.dock | grep \"Ignoring stack ~/Downloads: unknown view 'spiral'\"")
        # Same PID: a crash that the session respawned from would still pass a mere liveness check.
        assert machine.succeed("${dock}").strip() == dock_pid, "the dock restarted"

    with subtest("The dock zooms at its defaults without warnings"):
        machine.wait_until_succeeds("journalctl -b -t io.elementary.dock | grep 'DOCK_ZOOM_AT: zooming at 1.5 slots'")
        machine.succeed("su - alice -c '${bus} gsettings get io.elementary.dock zoom-size' | grep -qx 84")
        machine.fail("journalctl -b -t io.elementary.dock | grep 'zoom-size .* is outside'")
        machine.sleep(2)
        machine.screenshot("dock_zoomed")

    with subtest("An out-of-range zoom-size is clamped and logged, and the dock stays up"):
        machine.succeed("su - alice -c '${bus} gsettings set io.elementary.dock zoom-size 500'")
        machine.wait_until_succeeds("journalctl -b -t io.elementary.dock | grep 'zoom-size 500 is outside' | grep -q 'using 104'")
        assert machine.succeed("${dock}").strip() == dock_pid, "the dock restarted"
        machine.sleep(2)
        machine.screenshot("dock_zoomed_clamped")

    with subtest("The dock logged no crash"):
        machine.fail("journalctl -b -t io.elementary.dock | grep -E 'CRITICAL|g_error|Trace/breakpoint'")
  '';
}
