# Boots Pantheon with the patched dock and two stacks, and checks that the
# dock comes up with them and survives an invalid stacks value.
# Modelled on nixpkgs' nixos/tests/pantheon.nix, but with LightDM autologin
# instead of typing into the greeter.
{pkgs, ...}: {
  name = "pantheon-dock-stacks";

  nodes.machine = {...}: {
    imports = [
      "${pkgs.path}/nixos/tests/common/user-account.nix"
      ../modules/constellation/pantheon-dock.nix
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
        machine.fail("journalctl -b -t io.elementary.dock | grep 'Ignoring stack'")
        machine.screenshot("dock_stacks")

    with subtest("An invalid stack is logged and skipped, and the dock stays up"):
        machine.succeed("su - alice -c \"${bus} gsettings set io.elementary.dock stacks \\\"[('~/Downloads', 'spiral', 'name', 'stack')]\\\"\"")
        machine.wait_until_succeeds("journalctl -b -t io.elementary.dock | grep \"Ignoring stack ~/Downloads: unknown view 'spiral'\"")
        machine.succeed("${dock}")
  '';
}
