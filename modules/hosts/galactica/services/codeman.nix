# https://codeman.arsfeld.one: the Codeman agent dashboard, which runs on
# raider. Gateway-only, behind Authelia; raider's tailscale serve forwards
# :8443 to Codeman. Why it is built this way, and what it exposes:
# modules/hosts/raider/codeman.nix.
{
  configurations.nixos.galactica.module = {
    media.services.codeman = {
      host = "raider.bat-boa.ts.net";
      port = 8443;
    };
  };
}
