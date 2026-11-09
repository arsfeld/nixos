{
  symlinkJoin,
  writeShellApplication,
  curl,
  jq,
  coreutils,
  findutils,
}: let
  hook = writeShellApplication {
    name = "claude-board-hook";
    runtimeInputs = [curl jq coreutils findutils];
    text = builtins.readFile ./claude-board-hook;
  };
  install = writeShellApplication {
    name = "claude-board-install-hooks";
    runtimeInputs = [jq coreutils];
    text = builtins.readFile ./claude-board-install-hooks;
  };
in
  # Tests: bash packages/claude-board-hook/test/test.sh
  symlinkJoin {
    name = "claude-board-hook";
    paths = [hook install];
  }
