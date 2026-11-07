# Boots Pantheon and runs elementary Terminal on libghostty-gtk (packages/elementary-terminal-ghostty)
# with a script that emits an OSC 52 clipboard write, an OSC 2 title and a
# coloured word. Asserts the Wayland clipboard received the OSC 52 text and the
# title reached the window (read back by OCR: the header bar title is cropped
# from a screendump, as the driver's OCR does not read it). The node imports
# the pantheon-terminal feature, so the VM tests the real wiring. Modelled on
# pantheon-tailscale-test.
{self, ...}: {
  name = "pantheon-terminal";
  enableOCR = true;

  nodes.machine = {pkgs, ...}: {
    imports = [
      (import ../modules/desktop/pantheon-terminal.nix).flake.modules.nixos.pantheon-terminal
    ];

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

    environment.systemPackages = [pkgs.wl-clipboard];

    environment.etc."osc-check.sh" = {
      mode = "0755";
      text = ''
        #!${pkgs.runtimeShell}
        printf '\033]2;TITLEOK\007'
        printf '\033[31mRED\033[0m\n'
        printf '\033]52;c;%s\007' "$(printf e2e-ok | base64)"
        exec sleep infinity
      '';
    };
  };

  testScript = {nodes, ...}: let
    uid = toString nodes.machine.users.users.arosenfeld.uid;
    env = "XDG_CURRENT_DESKTOP=Pantheon XDG_RUNTIME_DIR=/run/user/${uid} WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus";
  in ''
    import subprocess

    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${uid}/wayland-0")
    machine.wait_until_succeeds("pgrep -f '(^|/)io\\.elementary\\.wingpanel$'")
    machine.wait_until_succeeds("pgrep -f '(^|/)io\\.elementary\\.dock$'")
    machine.wait_for_text("Applications")

    machine.succeed(
        "su - arosenfeld -c '${env} nohup io.elementary.terminal -e /etc/osc-check.sh >/tmp/terminal.log 2>&1 &'"
    )

    def header_text():
        # The driver's OCR does not read the bold header bar title, so crop
        # the bar, scale it up and OCR just that.
        machine.send_monitor_command("screendump /tmp/header.ppm")
        subprocess.run(
            ["magick", "/tmp/header.ppm", "-crop", "700x36+290+64", "+repage",
             "-colorspace", "Gray", "-resize", "400%", "-negate", "/tmp/header.png"],
            check=True,
        )
        return subprocess.run(
            ["tesseract", "/tmp/header.png", "-", "--psm", "7"], check=True, capture_output=True
        ).stdout.decode().strip()

    with subtest("The script's output and OSC 2 title are on screen"):
        machine.wait_for_text("RED", timeout=60)
        machine.screenshot("pantheon-terminal")
        # Only the header bar can show this: the command line says
        # osc-check.sh, and the tab labels show the user name.
        for _ in range(15):
            if header_text() == "TITLEOK":
                break
            machine.sleep(2)
        else:
            raise Exception("header bar title is %r, not TITLEOK" % header_text())

    with subtest("OSC 52 write reaches the Wayland clipboard"):
        machine.wait_until_succeeds(
            "su - arosenfeld -c '${env} wl-paste -n' | grep -x e2e-ok", timeout=60
        )
  '';
}
