# galactica: main server. Media services, databases, backups; *.arsfeld.one.
# Configuration in ./galactica/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.galactica = {
    tier = "tier1";
    module.imports = [
      inputs.disko.nixosModules.disko
      inputs.hermes-agent.nixosModules.default # services.hermes-agent, used by cylon-bot-voice.nix
      features.backrest
      features.backup-summary
      features.check-stock
      features.development
      features.forgejo-runner
      features.media
      features.podman
      features.tsnsrv
      features.virtualization
    ];
  };
}
