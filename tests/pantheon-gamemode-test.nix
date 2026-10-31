# Boots Pantheon with the GameMode indicator (modules/constellation/pantheon-gamemode.nix)
# and drives it with two fake games under gamemoderun: fake-game, named by its
# executable, and a binary named `reaper` launched the way Steam launches games,
# named from a Steam app manifest. Both are C, not `sleep`: nixpkgs' coreutils
# is multicall, so gamemoded would see every coreutils tool as `coreutils`.
# Wingpanel's own open-indicator action opens the popover, so nothing is
# clicked. The indicator logs each change and the names it shows; this asserts
# on those lines. Modelled on pantheon-dock-test.
{pkgs, ...}: let
  sleeper = name:
    pkgs.writeCBin name ''
      #include <unistd.h>
      int main(void) { sleep(600); return 0; }
    '';
  wingpanelAction = pkgs.writeShellScriptBin "wingpanel-action" ''
    exec ${pkgs.glib.bin}/bin/gdbus call --session --dest org.elementary.wingpanel \
      --object-path /org/elementary/wingpanel --method org.gtk.Actions.Activate \
      "$1-indicator" "[<'gamemode'>]" '{}'
  '';
in {
  name = "pantheon-gamemode";
  enableOCR = true;

  nodes.machine = {...}: {
    imports = [
      "${pkgs.path}/nixos/tests/common/user-account.nix"
      ../modules/constellation/pantheon-gamemode.nix
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

    programs.gamemode.enable = true;
    environment.systemPackages = [(sleeper "fake-game") (sleeper "reaper") wingpanelAction];
    environment.etc."fake-steam/appmanifest_4242.acf".text = ''
      "AppState"
      {
      	"appid"		"4242"
      	"name"		"Fake Quest"
      	"installdir"		"FakeQuest"
      }
    '';
  };

  testScript = {nodes, ...}: let
    user = nodes.machine.users.users.alice;
    bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
    panel = "pgrep -f '(^|/)io\\.elementary\\.wingpanel$'";
    log = "journalctl -b -t io.elementary.wingpanel";
  in ''
    def as_alice(cmd):
        return machine.succeed(f"su - alice -c '${bus} {cmd}'")

    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${toString user.uid}/wayland-0")

    with subtest("Wingpanel loads the indicator, hidden while no game runs"):
        machine.wait_until_succeeds("${panel}")
        machine.wait_until_succeeds(
            "su - alice -c '${bus} gdbus call --session --dest org.elementary.wingpanel "
            "--object-path /org/elementary/wingpanel --method org.gtk.Actions.DescribeAll' | grep -q gamemode"
        )
        panel_pid = machine.succeed("${panel}").strip()
        machine.fail("${log} | grep 'GameMode on'")

    with subtest("A game turns it on, and the popover names it"):
        as_alice("gamemoderun fake-game >/dev/null 2>&1 &")
        machine.wait_until_succeeds("${log} | grep -q 'GameMode on: 1 game(s)'")
        as_alice("wingpanel-action open")
        machine.wait_until_succeeds("${log} | grep -q 'Game Mode games: fake-game$'")
        # The log line only proves opened() ran; OCR proves the popover is on screen.
        machine.wait_for_text("Game Mode")
        machine.wait_for_text("fake-game")
        machine.screenshot("gamemode_popover")
        as_alice("wingpanel-action close")

    with subtest("A Steam game is named from its app manifest"):
        as_alice("mkdir -p ~/.local/share/Steam/steamapps && cp /etc/fake-steam/appmanifest_4242.acf ~/.local/share/Steam/steamapps/")
        as_alice("gamemoderun reaper SteamLaunch AppId=4242 -- /fake/game >/dev/null 2>&1 &")
        machine.wait_until_succeeds("${log} | grep -q 'GameMode on: 2 game(s)'")
        as_alice("wingpanel-action open")
        machine.wait_until_succeeds("${log} | grep 'Game Mode games:' | grep -q 'Fake Quest'")
        machine.wait_for_text("Fake Ques")
        machine.screenshot("gamemode_popover_steam")
        as_alice("wingpanel-action close")

    with subtest("It turns off once the games exit"):
        machine.succeed("pkill -x fake-game; pkill -x reaper")
        # gamemoded notices dead PIDs on its 5 s reaper pass.
        machine.wait_until_succeeds("${log} | grep -q 'GameMode off'", timeout=60)

    with subtest("The indicator logged no warning and the panel never restarted"):
        machine.fail("journalctl -b -q GLIB_DOMAIN=io.elementary.wingpanel.gamemode -p warning | grep .")
        assert machine.succeed("${panel}").strip() == panel_pid, "wingpanel restarted"
  '';
}
