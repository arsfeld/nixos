# stash-identify: watches the Stash library and, for every new file, runs Stash's own
# scan -> generate -> identify with the defaults saved in the Stash UI, then fills title,
# studio and performers on any scene still bare, using an LLM filename parse confirmed
# against StashDB/ThePornDB where it can. Guesses are tagged `llm-identified`. JAV files
# are looked up by product code first (StashDB, then ThePornDB's JAV API); FC2-PPV files
# by scraping the FC2 article through Stash, with the title translated to English.
#
# Design: docs/superpowers/specs/2026-09-27-stash-llm-identify-design.md
# JAV: docs/superpowers/specs/2026-09-28-stash-identify-jav-design.md
# Unit tests: `python3 -m unittest -v` in this directory.
{
  config,
  pkgs,
  ...
}: let
  keyFile = config.sops.secrets.openrouter-api-key.path;

  stashIdentify = pkgs.writeShellApplication {
    name = "stash-identify";
    runtimeInputs = [pkgs.inotify-tools];
    text = ''
      export OPENROUTER_API_KEY_FILE="''${OPENROUTER_API_KEY_FILE:-${keyFile}}"
      exec ${pkgs.python3}/bin/python3 ${./.}/main.py "$@"
    '';
  };
in {
  sops.secrets.openrouter-api-key.owner = "media";

  environment.systemPackages = [stashIdentify];

  systemd.services.stash-identify = {
    description = "Scan, generate and identify new Stash files";
    wantedBy = ["multi-user.target"];
    after = ["${config.virtualisation.oci-containers.backend}-stash.service" "mnt-storage.mount"];
    wants = ["${config.virtualisation.oci-containers.backend}-stash.service"];
    requires = ["mnt-storage.mount"];
    serviceConfig = {
      ExecStart = "${stashIdentify}/bin/stash-identify watch";
      User = "media";
      Group = "media";
      StateDirectory = "stash-identify";
      Restart = "always";
      RestartSec = "30s";
    };
  };
}
