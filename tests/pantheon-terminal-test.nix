# Boots Pantheon and runs elementary Terminal on gvt (packages/elementary-terminal-ghostty)
# with a script that emits an OSC 52 clipboard write, an OSC 2 title and a
# coloured word. Asserts the Wayland clipboard received the OSC 52 text and the
# title reached the window (read back by OCR: wait_for_window needs X11 tools
# and cannot see a Wayland window). Modelled on pantheon-tailscale-test.
{self, ...}: {
  name = "pantheon-terminal";
  enableOCR = true;

  nodes.machine = {pkgs, ...}: {
    nixpkgs.overlays = self.lib.overlays;

    # Workaround ".gala-wrapped invoked oom-killer" (as upstream's test).
    virtualisation.memorySize = 2047;

    users.users.arosenfeld = {
      isNormalUser = true;
      uid = 1000;
      password = "foobar";
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

    environment.systemPackages = [pkgs.elementary-terminal-ghostty pkgs.wl-clipboard];

    # Pantheon's own elementary-terminal is on PATH ahead of the overlay's, so
    # the test names the gvt build through this link.
    environment.etc."gvt-terminal".source = "${pkgs.elementary-terminal-ghostty}/bin/io.elementary.terminal";

    environment.etc."gvt-e2e.sh" = {
      mode = "0755";
      text = ''
        #!${pkgs.runtimeShell}
        printf '\033]2;gvt-e2e\007'
        printf '\033[31mRED\033[0m\n'
        # A Wayland compositor only accepts a clipboard write that follows
        # input to the window, so wait for a keypress before the OSC 52.
        read -r _
        printf '\033]52;c;%s\007' "$(printf e2e-ok | base64)"
        exec sleep infinity
      '';
    };
  };

  testScript = {nodes, ...}: let
    uid = toString nodes.machine.users.users.arosenfeld.uid;
    env = "XDG_RUNTIME_DIR=/run/user/${uid} WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus";
  in ''
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${uid}/wayland-0")
    machine.wait_until_succeeds("pgrep -f '(^|/)io\\.elementary\\.wingpanel$'")
    machine.wait_until_succeeds("pgrep -f '(^|/)io\\.elementary\\.dock$'")
    machine.wait_for_text("Applications")

    machine.succeed(
        "su - arosenfeld -c '${env} nohup /etc/gvt-terminal -e /etc/gvt-e2e.sh >/tmp/terminal.log 2>&1 &'"
    )

    with subtest("OSC 2 title and the coloured text are on screen"):
        try:
            machine.wait_for_text("RED", timeout=60)
            # A lone tab shows no tab bar; a second tab brings it up with
            # each tab labelled by its OSC 2 title.
            machine.send_key("ctrl-shift-t")
            machine.wait_for_text("gvt-e2e", timeout=30)
        except Exception:
            print(machine.execute("pgrep -af terminal; cat /tmp/terminal.log")[1])
            raise
        machine.screenshot("pantheon-terminal")

    with subtest("OSC 52 write reaches the Wayland clipboard"):
        # Close the second tab to land back on the script's.
        machine.send_key("ctrl-shift-w")
        machine.wait_for_text("RED")
        machine.send_chars("\n")
        machine.wait_until_succeeds(
            "su - arosenfeld -c '${env} wl-paste -n' | grep -x e2e-ok", timeout=60
        )
  '';
}
