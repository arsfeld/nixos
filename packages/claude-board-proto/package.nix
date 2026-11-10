{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "claude-board-proto";
  version = "0.1.0";
  # The tests parse the bridge's wire fixtures, so both directories are in the source.
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ../claude-board-bridge/tests/fixtures
    ];
  };
  sourceRoot = "source/claude-board-proto";
  cargoLock.lockFile = ./Cargo.lock;
  # A library: building it runs its tests (the default checkPhase), and that is the whole point.
  dontCargoInstall = true;
  installPhase = "mkdir -p $out";
  meta.description = "Wire types shared by the claude-board bridge and board firmware (built to run its tests)";
}
