# The token Claude Code hooks present to the cylon-bot bridge (galactica).
# Every host runs hooks, so every host materialises it at
# /run/secrets/cylon-bot-host-token for `cylon-bot-hook`, which reads it
# as the user that runs Claude Code. The bridge reads the same secret through
# LoadCredential (galactica restarts it when the token changes: see its service module). Design: docs/superpowers/specs/2026-11-09-cylon-bot-design.md
{
  flake.modules.nixos.base = {config, ...}: {
    key = "modules/base/cylon-bot";
    sops.secrets.cylon-bot-host-token = {
      sopsFile = config.constellation.sops.commonSopsFile;
      owner = "arosenfeld";
      mode = "0400";
    };
  };
}
