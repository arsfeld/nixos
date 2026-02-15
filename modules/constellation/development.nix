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

    nodejs = lib.mkEnableOption "Node.js development" // {default = true;};
    python = lib.mkEnableOption "Python development" // {default = true;};
    go = lib.mkEnableOption "Go development" // {default = true;};
    rust = lib.mkEnableOption "Rust development" // {default = true;};
    elixir = lib.mkEnableOption "Elixir development" // {default = true;};
    flutter = lib.mkEnableOption "Flutter/Dart development" // {default = true;};

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

        # Pre-commit
        prek

        # Modern CLI tools
        ripgrep
        fd
        bat
        eza
        zoxide
        fzf
        delta
        just
        hyperfine
        tokei
        procs
        dust
        bandwhich
        grex
        sd

        # System monitoring
        htop
        btop
        iotop
        nethogs
        ctop
      ]
      ++ lib.optionals config.constellation.development.nodejs [
        nodejs_20
        nodePackages.pnpm
        nodePackages.yarn
        bun
        deno
      ]
      ++ lib.optionals config.constellation.development.python [
        python3
        python3Packages.pip
        python3Packages.virtualenv
      ]
      ++ lib.optionals config.constellation.development.go [
        go
      ]
      ++ lib.optionals config.constellation.development.rust [
        rustup
      ]
      ++ lib.optionals config.constellation.development.elixir [
        elixir
        erlang
        elixir-ls
      ]
      ++ lib.optionals config.constellation.development.flutter [
        flutter
        dart
      ]
      ++ lib.optionals config.constellation.development.cloudTools [
        kubectl
        kubectx
        k9s
        kubernetes-helm
        opentofu
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
    environment.sessionVariables = lib.mkIf config.constellation.development.rust {
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
      # Note: conf.all.forwarding must also be set, as it overrides ip_forward
      "net.ipv4.conf.all.forwarding" = lib.mkDefault true;
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    };
  };
}
