# Transmission confined to PIA via the self-contained haugene/transmission-openvpn
# image. Unlike galactica (native transmission in a host WireGuard namespace),
# pegasus uses the all-in-one OpenVPN image so we don't have to stand up a host
# VPN namespace. The image has a built-in kill switch: only LOCAL_NETWORK traffic
# bypasses the tunnel, so a VPN drop stops torrent traffic rather than leaking.
#
# Exposed at transmission.arsfeld.xyz with bypassAuth at the gateway, protected
# by Transmission's own RPC auth (creds in the sops secret). mydia talks to it on
# localhost:9091.
{
  config,
  lib,
  self,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in
  lib.mkMerge [
    {
      sops.secrets.transmission-openvpn-pia = {
        sopsFile = ../../../secrets/sops/pegasus.yaml;
        mode = "0400";
      };
    }

    (mkService "transmission" {
      port = 9091;
      image = "haugene/transmission-openvpn:latest";
      host = "localhost";
      bypassAuth = true; # protected by Transmission RPC auth instead of Authelia
      container = {
        exposePort = 9091;
        configDir = "/config";
        environment = {
          # OPENVPN_* and TRANSMISSION_RPC_USERNAME/PASSWORD come from the secret.
          TRANSMISSION_RPC_AUTHENTICATION_REQUIRED = "true";
          # Flood web UI, to match galactica's Transmission (webHome = flood).
          TRANSMISSION_WEB_UI = "flood-for-transmission";
          # Permit the podman bridge, LAN and Tailscale to reach the web UI without
          # going through the VPN (everything else is kill-switched to the tunnel).
          LOCAL_NETWORK = "10.0.0.0/8,192.168.0.0/16,100.64.0.0/10";
          # /dev/net/tun is passed in via --device, so the image must not try to
          # mknod its own (that needs CAP_MKNOD and fails).
          CREATE_TUN_DEVICE = "false";
          # Use the host-identical path so mydia and transmission agree on where
          # downloads land (no remote-path mapping needed).
          TRANSMISSION_DOWNLOAD_DIR = "${vars.storageDir}/media/Downloads";
          TRANSMISSION_INCOMPLETE_DIR_ENABLED = "false";
          TRANSMISSION_RENAME_PARTIAL_FILES = "true";
          TRANSMISSION_RPC_HOST_WHITELIST_ENABLED = "false";
          TRANSMISSION_RPC_WHITELIST_ENABLED = "false";
        };
        environmentFiles = [config.sops.secrets.transmission-openvpn-pia.path];
        volumes = ["${vars.storageDir}/media:${vars.storageDir}/media"];
        extraOptions = [
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun"
        ];
      };
    })
  ]
