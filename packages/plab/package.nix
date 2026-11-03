{
  lib,
  rustPlatform,
  buildNpmPackage,
}: let
  # The Svelte app, served by plab from PLAB_STATIC_DIR. Its own derivation: a Rust change
  # does not rebuild it, and a UI change does not rebuild plab.
  ui = buildNpmPackage {
    pname = "plab-ui";
    version = "0.1.0";
    src = lib.fileset.toSource {
      root = ./ui;
      fileset = lib.fileset.unions [
        ./ui/package.json
        ./ui/package-lock.json
        ./ui/index.html
        ./ui/vite.config.ts
        ./ui/svelte.config.js
        ./ui/tsconfig.json
        ./ui/src
      ];
    };
    npmDepsHash = "sha256-T294U8tSMP74/egPh2bDbenNPpipO3CER7AsyNLxkOE=";
    # svelte-check and vitest gate the build, as cargo test gates plab's.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      npm run check
      npm test
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';
  };
in
  rustPlatform.buildRustPackage {
    pname = "plab";
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
    passthru = {inherit ui;};
    meta = {
      description = "plab: tracker app, Stash identification and studio grabs for galactica";
      mainProgram = "plab";
    };
  }
