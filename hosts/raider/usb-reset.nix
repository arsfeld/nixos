# `sudo raider-usb-reset`: recover keyboard, mouse and trackpad when the hub
# chain behind them (1-8 -> 1-8.2 -> 1-8.2.1, the monitor/dock hubs) wedges.
# The session then gets no input at all and looks like a frozen lock screen;
# `journalctl -k` shows a device on 1-8.2.1.4 looping `Device not responding
# to setup address`. Toggling `authorized` on the hubs and restarting greetd
# do not fix it. Rebinding the xHCI controller re-enumerates all of bus 1 and
# does. Run it over SSH, since raider has no local input at that point.
{pkgs, ...}: let
  controller = "0000:00:14.0";
  driver = "/sys/bus/pci/drivers/xhci_hcd";
in {
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "raider-usb-reset";
      runtimeInputs = [pkgs.coreutils pkgs.gnugrep];
      text = ''
        if [ "$(id -u)" -ne 0 ]; then
          echo "raider-usb-reset: run as root (sudo raider-usb-reset)" >&2
          exit 1
        fi

        echo ${controller} > ${driver}/unbind
        sleep 3
        echo ${controller} > ${driver}/bind
        sleep 5

        missing=0
        for dev in "Keychron K3" "Logitech USB Receiver Mouse" "Magic Trackpad"; do
          if grep -q "^N: Name=.*$dev" /proc/bus/input/devices; then
            echo "ok       $dev"
          else
            echo "missing  $dev"
            missing=1
          fi
        done
        exit "$missing"
      '';
    })
  ];
}
