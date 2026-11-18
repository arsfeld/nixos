# Office presence: is Alexandre's phone within Bluetooth range of raider, the
# desk in the basement office? galactica's Home Assistant polls
# http://raider.bat-boa.ts.net:8593/status and heats the office and the
# downstairs bathroom only while it is (see home-assistant-heating's "Office
# vacant"). The port needs no firewall rule: only tailscale0, which is
# trusted, reaches it.
#
# Measured 2026-11-17: the bonded phone answered l2ping steadily at the desk
# (about 1 echo in 6 lost) and not at all from most of the floor above, but
# one spot upstairs answered too, at RSSI -12 to -15 against 0 to -4 at the
# desk; Home Assistant counts only -8 or better as near. Pairing the phone made it an audio device;
# WirePlumber keeps its profile "off" (~/.local/state/wireplumber), so no
# phone audio routes through raider.
{
  configurations.nixos.raider.module = {
    config,
    lib,
    pkgs,
    ...
  }: {
    sops.secrets."office-presence-phone" = {};

    systemd.services.office-presence = {
      description = "Report whether the phone is near raider, for office heating";
      wantedBy = ["multi-user.target"];
      wants = ["bluetooth.service"];
      after = ["bluetooth.service"];
      path = [pkgs.bluez];
      environment.PHONE_FILE = "%d/phone";
      serviceConfig = {
        ExecStart = lib.getExe pkgs.office-presence;
        LoadCredential = "phone:${config.sops.secrets."office-presence-phone".path}";
        DynamicUser = true;
        # l2ping opens a raw L2CAP socket; btmgmt uses the HCI control channel.
        AmbientCapabilities = ["CAP_NET_RAW" "CAP_NET_ADMIN"];
        CapabilityBoundingSet = ["CAP_NET_RAW" "CAP_NET_ADMIN"];
        RestrictAddressFamilies = ["AF_BLUETOOTH" "AF_INET" "AF_INET6" "AF_UNIX"];
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
