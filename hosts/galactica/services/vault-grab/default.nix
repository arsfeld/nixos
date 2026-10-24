# vault-grab: one 1080p copy of every new scene from the studios in the
# `vault-grab-rules` secret, found through Prowlarr and added to Transmission
# under Vault/<Studio>. No page, no port: the journal is the record.
#
# Design: docs/superpowers/specs/2026-10-24-vault-grab-design.md
# Unit tests: `PYTHONPATH=../plab python3 -m unittest -v` in this directory.
# What would a run grab: `sudo -u media vault-grab run --dry-run`.
{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;

  vault-grab = pkgs.writeShellApplication {
    name = "vault-grab";
    text = ''
      export VAULT_GRAB_RULES_FILE="''${VAULT_GRAB_RULES_FILE:-${config.sops.secrets.vault-grab-rules.path}}"
      export VAULT_GRAB_STATE_DIR="''${VAULT_GRAB_STATE_DIR:-/var/lib/vault-grab}"
      export VAULT_GRAB_PROWLARR_URL="http://127.0.0.1:9696"
      # Read at run time: Prowlarr owns the key, so there is no second copy to drift.
      export VAULT_GRAB_PROWLARR_CONFIG="${vars.configDir}/prowlarr/config.xml"
      # Straight into the PIA namespace, never through the Authelia-gated
      # transmission vhost (see transmission-vpn.nix).
      export VAULT_GRAB_TRANSMISSION_URL="http://${config.constellation.pia.namespaceAddress}:9091/transmission/rpc"
      # plab's tree too; Transmission creates each <Studio> directory.
      export VAULT_GRAB_DOWNLOAD_DIR="${vars.storageDir}/media/Downloads/Vault"
      # plab's Transmission client, shared rather than copied.
      export PYTHONPATH="${../plab}"
      exec ${pkgs.python3}/bin/python3 ${./.}/main.py "$@"
    '';
  };
in {
  sops.secrets.vault-grab-rules.owner = vars.user;

  environment.systemPackages = [vault-grab];

  systemd.services.vault-grab = {
    description = "Grab new scenes of the followed studios into Vault";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = vars.user;
      Group = vars.group;
      StateDirectory = "vault-grab";
      ExecStart = "${vault-grab}/bin/vault-grab run";
    };
  };

  systemd.timers.vault-grab = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 01/3:30:00"; # between plab-refresh runs (00/3:00)
      OnBootSec = "5min";
      Persistent = true;
    };
  };
}
