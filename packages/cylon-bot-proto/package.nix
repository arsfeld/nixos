{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "cylon-bot-proto";
  version = "0.1.0";
  # The tests parse the bridge's wire fixtures, so both directories are in the source.
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ../cylon-bot-bridge/tests/fixtures
    ];
  };
  sourceRoot = "source/cylon-bot-proto";
  cargoLock.lockFile = ./Cargo.lock;
  # A library: building it runs its tests (the default checkPhase), and that is the whole point.
  dontCargoInstall = true;
  installPhase = "mkdir -p $out";
  meta.description = "Wire types shared by the cylon-bot bridge and board firmware (built to run its tests)";
}
