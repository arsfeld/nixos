{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "pia";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      (lib.fileset.maybeMissing ./tests)
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  # cargo test runs in checkPhase (the default): a failing test fails the galactica build.
  meta = {
    description = "PIA WireGuard control plane for galactica: connect, port forwarding, watchdog";
    mainProgram = "pia";
  };
}
