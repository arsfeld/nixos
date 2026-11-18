{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "office-presence";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;
  meta = {
    description = "Reports whether a phone is within Bluetooth range of raider, for office heating";
    mainProgram = "office-presence";
  };
}
