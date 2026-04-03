{
  self,
  inputs,
  ...
}: {
  perSystem = {
    config,
    self',
    inputs',
    pkgs,
    system,
    ...
  }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [
        (import ../overlays/python-packages.nix)
      ];
    };
    formatter = pkgs.alejandra;
    checks = {
      pre-commit-check = inputs.git-hooks.lib.${system}.run {
        src = self;
        hooks = {
          alejandra.enable = true;
          gptcommit = {
            enable = false;
            name = "gptcommit";
            entry = "${pkgs.gptcommit}/bin/gptcommit prepare-commit-msg";
            language = "system";
            stages = ["prepare-commit-msg"];
            always_run = true;
            pass_filenames = false;
            args = ["--commit-msg-file"];
          };
        };
      };
    };
    devShells.default = pkgs.mkShell {
      inherit (config.checks.pre-commit-check) shellHook;
      buildInputs = with pkgs;
        [
          # Nix tools
          alejandra
          attic-client
          (colmena.override {
            nix = inputs.determinate.inputs.nix.packages.${system}.nix;
            nix-eval-jobs = inputs.det-nix-eval-jobs.packages.${system}.default;
          })
          inputs.deploy-rs.packages."${pkgs.stdenv.hostPlatform.system}".default
          git
          jq
          just
          openssl
          inputs.sops-nix.packages."${pkgs.stdenv.hostPlatform.system}".sops-import-keys-hook
          sops
          ssh-to-age

          # Python tools
          black
          python3Packages.mkdocs
          python3Packages.mkdocs-material
          python3Packages.mkdocs-awesome-nav
          python3Packages.mkdocs-mermaid2-plugin
          python3Packages.mike
          python3Packages.pymdown-extensions

          # Git commit tools
          gptcommit
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          disko
          inputs.disko.packages."${pkgs.stdenv.hostPlatform.system}".default
        ]
        ++ config.checks.pre-commit-check.enabledPackages;
    };

    # Expose packages loaded via haumea
    packages = inputs.haumea.lib.load {
      src = ../packages;
      loader = inputs.haumea.lib.loaders.callPackage;
      inputs = {inherit pkgs;};
      transformer = inputs.haumea.lib.transformers.liftDefault;
    };

    legacyPackages.homeConfigurations.arosenfeld = inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        inputs.nix-index-database.homeModules.nix-index
        ../home/home.nix
        {
          # Specific to standalone home-manager
          nixpkgs.config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        }
      ];
    };
  };
}
