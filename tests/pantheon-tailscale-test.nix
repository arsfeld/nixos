# Boots Pantheon with the Tailscale indicator (modules/desktop/pantheon-tailscale.nix)
# and a tailscaled that has no control server, so it waits at NeedsLogin, switched off. Drives
# it through the paths that need no tailnet: the popover's /status fetch,
# writes through PATCH /prefs (the exact request the switch sends) as the
# operator and as a user who is not, and a tailscaled stop and start. The
# indicator logs each change; this asserts on those lines. Exit-node selection
# needs a control server and is covered by the unit tests and by acceptance on
# raider. Modelled on pantheon-gamemode-test.
{pkgs, ...}: let
  wingpanelAction = pkgs.writeShellScriptBin "wingpanel-action" ''
    exec ${pkgs.glib.bin}/bin/gdbus call --session --dest org.elementary.wingpanel \
      --object-path /org/elementary/wingpanel --method org.gtk.Actions.Activate \
      "$1-indicator" "[<'tailscale'>]" '{}'
  '';
  # Fails (curl -f) on anything but 2xx, so a 403 fails the command.
  wantRunning = pkgs.writeShellScriptBin "tailscale-want-running" ''
    exec ${pkgs.curl}/bin/curl -sf -X PATCH --unix-socket /run/tailscale/tailscaled.sock \
      -H 'Host: local-tailscaled.sock' -d "{\"WantRunningSet\":true,\"WantRunning\":$1}" \
      http://local-tailscaled.sock/localapi/v0/prefs
  '';
in {
  name = "pantheon-tailscale";
  enableOCR = true;

  nodes.machine = {...}: {
    imports = [
      (import ../modules/desktop/pantheon-tailscale.nix).flake.modules.nixos.pantheon-tailscale
    ];

    # Workaround ".gala-wrapped invoked oom-killer" (as upstream's test).
    virtualisation.memorySize = 2047;

    # The module grants --operator to arosenfeld, so the session user is that
    # user; bob is the control who is not the operator.
    users.users.arosenfeld = {
      isNormalUser = true;
      uid = 1000;
      password = "foobar";
    };
    users.users.bob = {
      isNormalUser = true;
      uid = 1001;
    };

    services.xserver.enable = true;
    services.desktopManager.pantheon.enable = true;
    services.displayManager = {
      defaultSession = "pantheon-wayland";
      autoLogin = {
        enable = true;
        user = "arosenfeld";
      };
    };

    services.tailscale.enable = true;
    environment.systemPackages = [wingpanelAction wantRunning];
  };

  testScript = {nodes, ...}: let
    user = nodes.machine.users.users.arosenfeld;
    bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
    panel = "pgrep -f '(^|/)io\\.elementary\\.wingpanel$'";
    log = "journalctl -b -t io.elementary.wingpanel";
  in ''
    LOG = "${log}"

    def as_user(cmd):
        return machine.succeed(f"su - arosenfeld -c '${bus} {cmd}'")

    # Lines can repeat (unreachable at startup, again after a stop), so each
    # step waits for one more matching line than there was before it.
    def count(pattern):
        return int(machine.succeed("%s | grep -cE '%s' || true" % (LOG, pattern)).strip())

    def wait_for_more(pattern, before, timeout=90):
        machine.wait_until_succeeds(
            "test $(%s | grep -cE '%s') -gt %d" % (LOG, pattern, before), timeout=timeout
        )

    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${toString user.uid}/wayland-0")

    with subtest("Wingpanel loads the indicator, which follows tailscaled to NeedsLogin, switched off"):
        machine.wait_until_succeeds("${panel}")
        machine.wait_until_succeeds(
            "su - arosenfeld -c '${bus} gdbus call --session --dest org.elementary.wingpanel "
            "--object-path /org/elementary/wingpanel --method org.gtk.Actions.DescribeAll' | grep -q tailscale"
        )
        panel_pid = machine.succeed("${panel}").strip()
        machine.wait_until_succeeds("%s | grep -q 'Tailscale: NeedsLogin, switched off$'" % LOG, timeout=90)

    with subtest("Opening the popover fetches /status and shows the state"):
        before = count("Tailscale status: ")
        as_user("wingpanel-action open")
        wait_for_more("Tailscale status: 0 exit node candidate", before)
        machine.wait_for_text("Needs login")
        machine.screenshot("tailscale_popover")
        as_user("wingpanel-action close")

    with subtest("Only the operator may write prefs"):
        machine.wait_until_succeeds("tailscale debug prefs | grep -q '\"OperatorUser\": \"arosenfeld\"'")
        machine.fail("su - bob -c 'tailscale-want-running true'")
        # A fresh tailscaled has WantRunning=false, so the indicator starts at
        # "NeedsLogin, switched off"; switching on moves it to plain NeedsLogin.
        before = count("Tailscale: NeedsLogin$")
        as_user("tailscale-want-running true")
        wait_for_more("Tailscale: NeedsLogin$", before)
        before = count("Tailscale: (Stopped|NeedsLogin, switched off)$")
        as_user("tailscale-want-running false")
        wait_for_more("Tailscale: (Stopped|NeedsLogin, switched off)$", before)
        before = count("Tailscale: NeedsLogin$")
        as_user("tailscale-want-running true")
        wait_for_more("Tailscale: NeedsLogin$", before)

    with subtest("tailscaled stopping and starting is followed"):
        before = count("Tailscale: unreachable$")
        machine.succeed("systemctl stop tailscaled")
        wait_for_more("Tailscale: unreachable$", before)
        # Without a login, a restarted tailscaled has been observed to come back
        # switched off, as on a fresh boot.
        before = count("Tailscale: NeedsLogin, switched off$")
        machine.succeed("systemctl start tailscaled")
        wait_for_more("Tailscale: NeedsLogin, switched off$", before)

    with subtest("The indicator logged no warning and the panel never restarted"):
        # Positive control: the domain filter does match the indicator's messages.
        machine.succeed("journalctl -b -q GLIB_DOMAIN=io.elementary.wingpanel.tailscale | grep -q 'Tailscale: NeedsLogin'")
        machine.fail("journalctl -b -q GLIB_DOMAIN=io.elementary.wingpanel.tailscale -p warning | grep .")
        assert machine.succeed("${panel}").strip() == panel_pid, "wingpanel restarted"
  '';
}
