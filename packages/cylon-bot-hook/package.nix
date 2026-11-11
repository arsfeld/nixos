{
  symlinkJoin,
  writeShellApplication,
  curl,
  jq,
  coreutils,
  findutils,
}: let
  hook = writeShellApplication {
    name = "cylon-bot-hook";
    runtimeInputs = [curl jq coreutils findutils];
    text = builtins.readFile ./cylon-bot-hook;
  };
  install = writeShellApplication {
    name = "cylon-bot-install-hooks";
    runtimeInputs = [jq coreutils];
    text = builtins.readFile ./cylon-bot-install-hooks;
  };
in
  # Tests: bash packages/cylon-bot-hook/test/test.sh
  symlinkJoin {
    name = "cylon-bot-hook";
    paths = [hook install];
  }
