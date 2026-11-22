{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "system-report";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;
  # cargo test runs in checkPhase: a failing test fails every host's build.
  meta = {
    description = "Mails unit failures and deploys once a NixOS system settles";
    mainProgram = "system-report";
  };
}
