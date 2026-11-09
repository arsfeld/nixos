{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "claude-board-bridge";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  # cargo test runs in checkPhase (the default): a failing test fails the galactica build.
  meta = {
    description = "Relays Claude Code hook events to the ESP32 session board and its answers back";
    mainProgram = "claude-board-bridge";
  };
}
