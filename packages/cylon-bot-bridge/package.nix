{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "cylon-bot-bridge";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
      ../cylon-bot-proto/Cargo.toml
      ../cylon-bot-proto/src
    ];
  };
  sourceRoot = "source/cylon-bot-bridge";
  cargoLock.lockFile = ./Cargo.lock;
  # cargo test runs in checkPhase (the default): a failing test fails the galactica build.
  meta = {
    description = "Relays Claude Code hook events to the ESP32 session board and its answers back";
    mainProgram = "cylon-bot-bridge";
  };
}
