# plab: the tracker's most-seeded video releases of the last week, as a card grid with
# each post's images and an "Add to Vault" button that hands the torrent to Transmission.
#
# Design: docs/superpowers/specs/2026-10-09-plab-design.md
# Unit tests: `python3 -m unittest -v` in this directory.
#
# If a login ever hits a captcha, refresh fails (the page keeps its last list) and the
# button says "login needs captcha": log in once in a browser and run
# `sudo -u media plab set-cookie <bb_data cookie value>`. No restart needed: the running
# server notices the newer cookies.txt and uses it before it would try to log in.
{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
  secrets = config.sops.secrets;
  port = 8577;

  plab = pkgs.writeShellApplication {
    name = "plab";
    text = ''
      export PLAB_USERNAME_FILE="''${PLAB_USERNAME_FILE:-${secrets.plab-username.path}}"
      export PLAB_PASSWORD_FILE="''${PLAB_PASSWORD_FILE:-${secrets.plab-password.path}}"
      export PLAB_STATE_DIR="''${PLAB_STATE_DIR:-/var/lib/plab}"
      # Straight into the PIA namespace, never through the Authelia-gated
      # transmission vhost (see transmission-vpn.nix).
      export PLAB_TRANSMISSION_URL="http://${config.constellation.pia.namespaceAddress}:9091/transmission/rpc"
      # The path Prowlarr's `Vault` category produces too; a symlink to ../Vault.
      export PLAB_DOWNLOAD_DIR="${vars.storageDir}/media/Downloads/Vault"
      exec ${pkgs.python3}/bin/python3 ${./.}/main.py "$@"
    '';
  };

  serviceConfig = {
    User = vars.user;
    Group = vars.group;
    StateDirectory = "plab";
    UMask = "0077"; # cookies.txt is the session credential
  };
in {
  sops.secrets.plab-username.owner = vars.user;
  sops.secrets.plab-password.owner = vars.user;

  environment.systemPackages = [plab];

  # host: the default (the hostname) resolves to 127.0.0.2 here, and plab listens
  # on 127.0.0.1 only. Authelia-gated: no bypassAuth.
  media.services.plab = {
    inherit port;
    host = "127.0.0.1";
  };

  systemd.services.plab = {
    description = "plab page";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig =
      serviceConfig
      // {
        ExecStart = "${plab}/bin/plab serve --bind 127.0.0.1 --port ${toString port}";
        Restart = "always";
        RestartSec = "10s";
      };
  };

  systemd.services.plab-refresh = {
    description = "Refresh plab's list from the tracker";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig =
      serviceConfig
      // {
        Type = "oneshot";
        ExecStart = "${plab}/bin/plab refresh";
      };
  };

  systemd.timers.plab-refresh = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 00/3:00:00";
      OnBootSec = "2min";
      Persistent = true;
    };
  };
}
