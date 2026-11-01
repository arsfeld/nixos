# ASUS G14 hardware: supergfxd, asusd fan curves, asus-shutdown, keyboard-backlight rebind.
{
  configurations.nixos.blackbird.module = {pkgs, ...}: {
    # asus-shutdown ignores SIGTERM and its upstream unit sets SendSIGKILL=no with
    # TimeoutStopSec=45, so restarting it on a switch never succeeds: the stop
    # phase blocks ~90 s (with NetworkManager and every other changed unit already
    # stopped, i.e. no Wi-Fi), then the start fails and the switch exits 4. It only
    # acts at shutdown, so let a new version take over at the next boot instead.
    systemd.services.asus-shutdown.restartIfChanged = false;

    # ASUS G14 specific hardware support
    services.supergfxd.enable = true; # ASUS GPU switching
    services.asusd = {
      enable = true;
      fanCurvesConfig = {
        text = ''
          (
              profiles: (
                  balanced: [
                      (
                          fan: CPU,
                          pwm: (0, 0, 0, 38, 89, 128, 191, 255),
                          temp: (30, 40, 50, 65, 75, 80, 90, 100),
                          enabled: true,
                      ),
                      (
                          fan: GPU,
                          pwm: (0, 0, 0, 26, 77, 115, 179, 255),
                          temp: (30, 40, 50, 65, 75, 80, 90, 100),
                          enabled: true,
                      ),
                  ],
                  performance: [],
                  quiet: [],
                  custom: [],
              ),
          )
        '';
      };
    };

    # On GA401IU, the keyboard backlight goes dark across suspend/hibernate
    # cycles -- writes to /sys/class/leds/asus::kbd_backlight/brightness keep
    # reporting the correct value but the LEDs themselves stop responding.
    # Rebinding the asus HID driver (the one that exposes the kbd_backlight
    # LED via HID feature reports) reinitializes the path and brings the
    # lights back. Run on post-sleep for any sleep action.
    environment.etc."systemd/system-sleep/asus-kbd-rebind".source = pkgs.writeShellScript "asus-kbd-rebind" ''
      case "$1" in
        post)
          for dev in /sys/bus/hid/drivers/asus/*0B05:1866*; do
            [ -L "$dev" ] || continue
            id=''${dev##*/}
            echo "$id" > /sys/bus/hid/drivers/asus/unbind 2>/dev/null || true
            echo "$id" > /sys/bus/hid/drivers/asus/bind 2>/dev/null || true
          done
          ;;
      esac
    '';
  };
}
