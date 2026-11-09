# The token Claude Code hooks present to the claude-board bridge (galactica).
# Every host runs hooks, so every host materialises it at
# /run/secrets/claude-board-host-token for `claude-board-hook`, which reads it
# as the user that runs Claude Code. The bridge reads the same secret through
# LoadCredential (galactica restarts it when the token changes: see its service module). Design: docs/superpowers/specs/2026-11-09-claude-board-design.md
{
  flake.modules.nixos.base = {config, ...}: {
    key = "modules/base/claude-board";
    sops.secrets.claude-board-host-token = {
      sopsFile = config.constellation.sops.commonSopsFile;
      owner = "arosenfeld";
      mode = "0400";
    };
  };
}
