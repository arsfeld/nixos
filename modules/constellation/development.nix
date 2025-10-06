# Development environment configuration for constellation
# Provides Docker-based development with easy gaming mode toggle
{
  config,
  pkgs,
  lib,
  ...
}: {
  options.constellation.development = {
    enable = lib.mkEnableOption "development environment with Docker";

    docker = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Docker for containerized development";
    };

    languages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["nodejs" "python" "go" "rust"];
      description = "Programming languages to install";
    };

    cloudTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install cloud development tools (kubectl, terraform, etc.)";
    };
  };

  config = lib.mkIf config.constellation.development.enable {
    # Docker configuration
    virtualisation.docker = lib.mkIf config.constellation.development.docker {
      enable = true;
      enableOnBoot = false; # Manual control for gaming

      daemon.settings = {
        # storage-driver removed - let Docker choose the best driver
        registry-mirrors = ["https://mirror.gcr.io"];
        log-driver = "json-file";
        log-opts = {
          max-size = "10m";
          max-file = "3";
        };
      };

      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = ["--all" "--volumes"];
      };
    };

    # Development packages
    environment.systemPackages = with pkgs;
      [
        # Version control
        git
        gh
        lazygit
        sublime-merge
        git-crypt

        # Editors
        vscode
        neovim
        helix

        # Docker tools
        docker-compose
        docker-buildx
        lazydocker
        dive

        # Development utilities
        jq
        yq
        tmux
        direnv
        watchman
        httpie
        curl

        # Compilers and build tools
        clang
        pkg-config
        openssl
        openssl.dev

        # Modern CLI tools
        ripgrep
        fd
        bat
        eza
        zoxide
        fzf
        delta

        # System monitoring
        htop
        btop
        iotop
        nethogs
        ctop
      ]
      ++ lib.optionals (builtins.elem "nodejs" config.constellation.development.languages) [
        nodejs_20
        nodePackages.pnpm
        nodePackages.yarn
      ]
      ++ lib.optionals (builtins.elem "python" config.constellation.development.languages) [
        python3
        python3Packages.pip
        python3Packages.virtualenv
      ]
      ++ lib.optionals (builtins.elem "go" config.constellation.development.languages) [
        go
      ]
      ++ lib.optionals (builtins.elem "rust" config.constellation.development.languages) [
        rustup
      ]
      ++ lib.optionals config.constellation.development.cloudTools [
        kubectl
        kubectx
        k9s
        helm
        terraform
        awscli2
        google-cloud-sdk
        azure-cli
      ];

    # Shell aliases
    programs.bash.shellAliases = lib.mkIf config.constellation.development.docker {
      # Docker shortcuts
      dc = "docker-compose";
      dcu = "docker-compose up -d";
      dcd = "docker-compose down";
      dcl = "docker-compose logs -f";
      dps = "docker ps";

      # Docker management
      docker-stop-all = "docker stop $(docker ps -q)";
      docker-clean = "docker system prune -af --volumes";
      docker-reset = "systemctl restart docker";

      # Development helpers
      dev-status = "systemctl status docker && docker ps";
    };

    # User configuration
    users.users.arosenfeld = lib.mkIf config.constellation.development.docker {
      extraGroups = ["docker"];
    };

    # Environment variables for Rust development
    environment.sessionVariables = lib.mkIf (builtins.elem "rust" config.constellation.development.languages) {
      PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
      OPENSSL_DIR = "${pkgs.openssl.dev}";
      OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
      OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
    };

    # Performance tuning for development
    boot.kernel.sysctl = {
      # Increase inotify watchers for IDEs
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 512;

      # Better performance for containers
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    };
  };
}
