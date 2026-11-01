# Stash: its sops secrets, the stashapp-tools/stashPython overlay, the service and its unit override.
{
  configurations.nixos.raider.module = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Stash secrets
    sops.secrets."stash-jwt-secret" = {
      owner = "media";
      group = "media";
    };
    sops.secrets."stash-session-secret" = {
      owner = "media";
      group = "media";
    };

    # Create stashapp-tools Python package (needed by AI Tagger plugin)
    nixpkgs.overlays = [
      (final: prev: {
        stashapp-tools = prev.python3Packages.buildPythonPackage rec {
          pname = "stashapp-tools";
          version = "0.2.59";
          format = "setuptools";

          src = prev.fetchPypi {
            inherit pname version;
            hash = "sha256-Y52YueWHp8C2FsnJ01YMBkz4O2z4d7RBeCswWGr8SjY=";
          };

          propagatedBuildInputs = with prev.python3Packages; [
            requests
          ];

          pythonImportsCheck = ["stashapi"];
        };

        # Python environment with required packages for Stash plugins
        stashPython = prev.python3.withPackages (ps:
          with ps; [
            final.stashapp-tools
            aiohttp
            pydantic
          ]);
      })
    ];

    # Stash media organizer
    services.stash = let
      # Fetch the CommunityScripts repository once
      communityScripts = pkgs.fetchFromGitHub {
        owner = "stashapp";
        repo = "CommunityScripts";
        rev = "eff9999aa884f030701f70dee36711603bab8b6d";
        hash = "sha256-Bx4C1Ms5ziQAQTvdhgvIM4ZlBS3IqWNiJK0VEypKxEA=";
        sparseCheckout = ["plugins"];
      };

      # Helper to create plugin packages
      mkStashPlugin = pluginName:
        pkgs.runCommand "stash-plugin-${pluginName}" {} ''
          mkdir -p $out
          cp -r ${communityScripts}/plugins/${pluginName}/* $out/
        '';

      # Workaround for nixpkgs bug: passwordFile is read unconditionally even when null
      # Create an empty file since we don't want authentication
      emptyPasswordFile = pkgs.writeText "empty-password" "";
    in {
      enable = true;
      openFirewall = true; # Allow access through port 9999
      user = "media";
      group = "media";
      username = "dummy"; # Required by assertion, but empty password = no auth
      passwordFile = emptyPasswordFile; # Dummy file to work around module bug
      jwtSecretKeyFile = config.sops.secrets."stash-jwt-secret".path;
      sessionStoreKeyFile = config.sops.secrets."stash-session-secret".path;
      mutablePlugins = false;
      mutableSettings = false; # Force config.yml regeneration to include plugins_path
      plugins = [
        (mkStashPlugin "CommunityScriptsUILibrary") # UI library used by other community plugins
        (mkStashPlugin "stashAI") # AI-powered features
      ];
      settings = {
        host = "0.0.0.0";
        sequential_scanning = true;
        parallel_tasks = 5;
        stash = [
          {
            path = "/mnt/games/Stash";
          }
        ];
      };
    };

    # Override Stash systemd service to use custom Python with stashapp-tools
    systemd.services.stash = {
      path = lib.mkForce (with pkgs; [
        coreutils # Provides install, env, and other basic utilities
        ffmpeg-full
        stashPython
        ruby
      ]);

      # Configure ffmpeg to use Intel iGPU for hardware video acceleration
      environment = {
        LIBVA_DRIVER_NAME = "iHD"; # Intel media driver for Gen 8+ GPUs
        LIBVA_DEVICE = "/dev/dri/renderD129"; # Intel iGPU render device
      };
    };
  };
}
