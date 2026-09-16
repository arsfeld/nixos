# eufy-sdk bridge — the server half of Home Assistant's Eufy Security
# integration (packages/home-assistant-eufy-sdk). It holds the eufy login and
# exposes devices over a WebSocket on :3000, plus go2rtc's RTSP on :8554.
#
# The WebSocket has no authentication, so there is deliberately no gateway
# entry and no tailscaleExposed: both ports are published on loopback only,
# where the native home-assistant service reaches them. Configure the
# integration with host 127.0.0.1, port 3000. The integration builds camera
# stream URLs as rtsp://<that host>:8554/<serial>, which is why 8554 is
# published too. WebRTC (8555/udp) would need host networking, so it is left
# out; HA's stream component plays the RTSP feed instead.
#
# The account is a secondary eufy account the main one shares its home with:
# eufy allows one session per account, so the bridge on the main account would
# be logged out whenever the phone app opens. The session token persists in
# /var/data/eufy-sdk-bridge, so restarts do not re-trigger 2FA.
#
# The image tag is pinned, not watched: bump it together with the integration.
{config, ...}: {
  sops.secrets."eufy-sdk-bridge-env" = {
    restartUnits = ["${config.virtualisation.oci-containers.backend}-eufy-sdk-bridge.service"];
  };

  media.services.eufy-sdk-bridge = {
    image = "ghcr.io/mega-yfue/ha-eufy-sdk-bridge:0.2.0";
    container = {
      configDir = "/app/data";
      environmentFiles = [config.sops.secrets."eufy-sdk-bridge-env".path]; # EUFY_EMAIL, EUFY_PASSWORD
      environment.EUFY_COUNTRY = "CA";
      extraOptions = [
        "--publish=127.0.0.1:3000:3000"
        "--publish=127.0.0.1:8554:8554"
      ];
    };
  };
}
