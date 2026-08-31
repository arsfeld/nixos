{pkgs, ...}: let
  inherit (pkgs) lib rustPlatform fetchFromGitHub cacert git;
in
  rustPlatform.buildRustPackage rec {
    pname = "codexify";
    version = "1.1.0";

    src = fetchFromGitHub {
      owner = "devnoname120";
      repo = "codexify";
      rev = "v${version}";
      hash = "sha256-gyZvfcy8M/DhYEOiUSdpcNl/YId6tGePTcp2a081CAM=";
    };

    cargoHash = "sha256-dB5D03rGubCRwyygQrHICwwWTgXzeDA70jj7zpXyGi0=";

    # The test suite shells out to git (diff/, project_clone/, tools::git_push)
    # and builds a reqwest client whose rustls backend loads the *system* trust
    # store even for the loopback fixture servers — with no CA bundle the
    # builder itself errors out, which is why the bridge:: tests fail seeing
    # zero tools rather than a connection error.
    nativeCheckInputs = [git cacert];

    preCheck = ''
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      export HOME=$(mktemp -d)
      export GIT_CONFIG_GLOBAL=$HOME/.gitconfig
      git config --global user.email codexify@localhost
      git config --global user.name codexify
      git config --global init.defaultBranch main
    '';

    meta = {
      description = "Local Rust MCP bridge exposing Codex-style agent tools to ChatGPT";
      homepage = "https://codexify.dev";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
      mainProgram = "codexify";
    };
  }
