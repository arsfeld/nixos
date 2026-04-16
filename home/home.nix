{
  config,
  pkgs,
  lib,
  inputs,
  osConfig ? null,
  ...
}: let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf optionals mkBefore; # Added mkBefore
  nvidia-offload = pkgs.writeShellScriptBin "nvidia-offload" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec "$@"
  '';

  claude-notify = pkgs.writeScriptBin "claude-notify" (builtins.readFile ./scripts/claude-notify);

  linuxOnlyPkgs = with pkgs;
    optionals stdenv.isLinux [
      distrobox
      nvidia-offload
      waypipe
    ];
in {
  imports = [
    ./ghostty.nix
    ./helix.nix
    ./mangohud.nix
    ./neovim.nix
    ./niri.nix
  ];

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home = {
    username = "arosenfeld";
    homeDirectory =
      if stdenv.isLinux
      then "/home/arosenfeld"
      else "/Users/arosenfeld";
    stateVersion = "22.05";

    # NPM configuration
    file.".npmrc".text = ''
      prefix=$HOME/.npm-global
    '';
    packages = with pkgs;
      [
        android-tools
        btop
        bottom
        cachix
        czkawka
        deno
        devbox
        devenv
        direnv
        doggo
        dust
        jq
        just
        fastfetch
        fd
        flyctl
        fortune
        gh
        git-lfs
        glances
        htop
        kondo
        kotlin
        mosh
        nil
        nodejs
        procs
        ripgrep
        ruby
        rustup
        starship
        tldr
        uv
        vim
        yt-dlp
        zellij

        (python3.withPackages (ps: with ps; [llm llm-gemini]))

        (writeScriptBin "murder" (builtins.readFile ./scripts/murder))
        (writeScriptBin "running" (builtins.readFile ./scripts/running))
        (writeScriptBin "claude-worktree" (builtins.readFile ./scripts/claude-worktree))
        claude-notify
        pkgs.playwright-mcp
        bun
        seafile-shared
      ]
      ++ linuxOnlyPkgs; # Added linuxOnlyPkgs
    sessionVariables =
      {
        PNPM_HOME = "$HOME/.local/share/pnpm";
        NPM_CONFIG_PREFIX = "$HOME/.npm-global";
        CLAUDE_NTFY_TOPIC = "claude";
      }
      // (
        if stdenv.isDarwin
        then {
          ANDROID_HOME = "$HOME/Library/Android/sdk";
        }
        else {}
      );
    sessionPath =
      [
        "$HOME/.local/bin"
        "$HOME/.local/share/pnpm"
        "$HOME/.npm-global/bin"
        "$HOME/.bun/bin"
      ]
      ++ (
        if stdenv.isDarwin
        then [
          "$HOME/Library/Android/sdk/emulator"
          "$HOME/Library/Android/sdk/platform-tools"
        ]
        else []
      );
    shellAliases = {
      "df" = "df -h -x tmpfs";
      "terraform" = "tofu";
      "tf" = "tofu";
    };

    shell = {
      enableBashIntegration = true;
      enableFishIntegration = true;
      enableZshIntegration = true;
    };
  };

  # This should be enabled by default, but being explicit here
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  # Configure nix settings for user
  nix = {
    package = lib.mkDefault pkgs.nix;
    settings =
      {
        builders-use-substitutes = true;
      }
      // (lib.optionalAttrs (osConfig != null && osConfig.networking.hostName != "basestar") {
        # Use remote builders configuration (skip on basestar to avoid circular dependency)
        builders = "@${../nix-builders.conf}";
      });
  };

  # programs.java.enable = true;

  xdg.configFile."starship.toml" = {
    source = ./files/starship.toml;
  };
  xdg.configFile."htop/htoprc" = {
    source = ./files/htoprc;
  };

  programs.home-manager.enable = true;

  # Set default applications for XDG MIME types
  xdg.mimeApps = mkIf stdenv.isLinux {
    enable = true;
    defaultApplications = {
      "text/html" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/http" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/https" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/about" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/unknown" = "app.zen_browser.zen.desktop";
    };
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      # Add local bin directories to PATH
      if test -d $HOME/.local/bin
        fish_add_path -g $HOME/.local/bin
      end
      if test -d $HOME/.npm-global/bin
        fish_add_path -g $HOME/.npm-global/bin
      end

      # Homebrew macOS
      if test -f /opt/homebrew/bin/brew
        eval (/opt/homebrew/bin/brew shellenv)
      end

      # Homebrew Linux
      if test -f /home/linuxbrew/.linuxbrew/bin/brew
        eval (/home/linuxbrew/.linuxbrew/bin/brew shellenv)
      end

      # Auto-attach to zellij on SSH or mosh
      # SSH sets SSH_TTY, mosh sets SSH_CONNECTION but not SSH_TTY
      if test -z "$ZELLIJ"
        if test -n "$SSH_TTY"; or test -n "$SSH_CONNECTION"
          # Fix TERM for mosh which may not set proper TERM
          switch "$TERM"
            case "mosh*" "dumb" ""
              set -gx TERM xterm-256color
          end
          zellij attach --create main
        end
      end
    '';
    functions = {
      backlog = ''
        set current_dir $PWD
        set found_root ""

        # Search up the directory tree for backlog/ folder
        while test "$current_dir" != "/"
          if test -d "$current_dir/backlog"
            set found_root "$current_dir"
            break
          end
          set current_dir (dirname "$current_dir")
        end

        # If found, cd to that directory and run backlog.md
        if test -n "$found_root"
          begin
            cd "$found_root"
            and ${pkgs.nodejs}/bin/npx -y backlog.md@latest $argv
          end
        else
          # Fallback to current behavior
          ${pkgs.nodejs}/bin/npx -y backlog.md@latest $argv
        end
      '';
      ip = ''
        if test "$argv[1]" = "addr" -o "$argv[1]" = "a"
          command ip $argv | awk '/^[0-9]+: (docker|veth|br-)/ { skip=1; next } /^[0-9]+: / { skip=0 } !skip'
        else
          command ip $argv
        end
      '';
      cc = ''
        # cc - Claude Code project launcher
        # Usage: cc [project]
        #   cc           - fuzzy select project, open in zellij + run claude
        #   cc nixos     - open nixos project in zellij + run claude

        set -l project $argv[1]

        # Get project path
        if test -z "$project"
          # Fuzzy select with zoxide
          set project (zoxide query -l | fzf --height 40% --reverse --prompt="Project: ")
          if test -z "$project"
            return 1
          end
        else
          # Resolve via zoxide
          set project (zoxide query $project 2>/dev/null)
          if test $status -ne 0
            echo "Project not found: $argv[1]"
            return 1
          end
        end

        set -l session_name (basename $project)

        if test -n "$ZELLIJ"
          # Already in zellij - create new tab and run claude
          zellij action new-tab --layout default --name $session_name --cwd $project
          zellij action write-chars "claude --dangerously-skip-permissions"
          zellij action write 10
        else
          # Outside zellij - attach or create session with claude
          if zellij list-sessions 2>/dev/null | grep -q "^$session_name\$"
            zellij attach $session_name
          else
            cd $project && zellij --session $session_name options --default-shell fish -c "claude --dangerously-skip-permissions"
          end
        end
      '';
      ccs = ''
        # ccs - Claude Code Sessions manager
        # Usage: ccs [kill <name>]
        if test "$argv[1]" = "kill"
          zellij kill-session $argv[2]
        else
          zellij list-sessions
        end
      '';
    };
  };

  programs.tmux = {
    enable = true;
    clock24 = true;
    newSession = true;
    extraConfig = ''
      # Set new panes to open in current directory
      bind c new-window -c "#{pane_current_path}"
      bind '"' split-window -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"
    '';
  };

  programs.bash = {
    enable = true;
    initExtra = ''
      # Smart backlog function that finds project root
      backlog() {
        local current_dir="$PWD"
        local found_root=""

        # Search up the directory tree for backlog/ folder
        while [[ "$current_dir" != "/" ]]; do
          if [[ -d "$current_dir/backlog" ]]; then
            found_root="$current_dir"
            break
          fi
          current_dir="$(dirname "$current_dir")"
        done

        # If found, cd to that directory and run backlog.md
        if [[ -n "$found_root" ]]; then
          (cd "$found_root" && ${pkgs.nodejs}/bin/npx -y backlog.md@latest "$@")
        else
          # Fallback to current behavior
          ${pkgs.nodejs}/bin/npx -y backlog.md@latest "$@"
        fi
      }

      # Filter out docker interfaces from ip addr
      ip() {
        if [[ "$1" == "addr" || "$1" == "a" ]]; then
          command ip "$@" | awk '/^[0-9]+: (docker|veth|br-)/ { skip=1; next } /^[0-9]+: / { skip=0 } !skip'
        else
          command ip "$@"
        fi
      }

      # cc - Claude Code project launcher (always runs claude)
      cc() {
        local project="$1"

        if [[ -z "$project" ]]; then
          project=$(zoxide query -l | fzf --height 40% --reverse --prompt="Project: ")
          [[ -z "$project" ]] && return 1
        else
          project=$(zoxide query "$project" 2>/dev/null) || {
            echo "Project not found: $1"
            return 1
          }
        fi

        local session_name=$(basename "$project")

        if [[ -n "$ZELLIJ" ]]; then
          zellij action new-tab --layout default --name "$session_name" --cwd "$project"
          zellij action write-chars "claude --dangerously-skip-permissions"
          zellij action write 10
        else
          if zellij list-sessions 2>/dev/null | grep -q "^''${session_name}$"; then
            zellij attach "$session_name"
          else
            cd "$project" && zellij --session "$session_name" -c "claude --dangerously-skip-permissions"
          fi
        fi
      }

      # ccs - Claude Code Sessions manager
      ccs() {
        if [[ "$1" == "kill" ]]; then
          zellij kill-session "$2"
        else
          zellij list-sessions
        fi
      }

      # Auto-attach to zellij on SSH or mosh
      # SSH sets SSH_TTY, mosh sets SSH_CONNECTION but not SSH_TTY
      if [[ -z "$ZELLIJ" ]]; then
        if [[ -n "$SSH_TTY" || -n "$SSH_CONNECTION" ]]; then
          # Fix TERM for mosh which may not set proper TERM
          case "$TERM" in
            mosh*|dumb|"")
              export TERM=xterm-256color
              ;;
          esac
          zellij attach --create main
        fi
      fi
    '';
    profileExtra = ''
      if [[ -s /etc/set-environment ]]; then
        . /etc/set-environment
      fi
    '';
  };

  programs.git = {
    enable = true;
    #delta.enable = true;
    settings = {
      user = {
        email = "arsfeld@gmail.com";
        name = "Alexandre Rosenfeld";
      };
      credential = {
        helper = "store";
      };
    };
  };

  programs.topgrade.enable = true;

  programs.gitui = {
    enable = true;
    theme = ''
      (
        selected_tab: Some("Reset"),
        command_fg: Some("#cad3f5"),
        selection_bg: Some("#5b6078"),
        selection_fg: Some("#cad3f5"),
        cmdbar_bg: Some("#1e2030"),
        cmdbar_extra_lines_bg: Some("#1e2030"),
        disabled_fg: Some("#8087a2"),
        diff_line_add: Some("#a6da95"),
        diff_line_delete: Some("#ed8796"),
        diff_file_added: Some("#a6da95"),
        diff_file_removed: Some("#ee99a0"),
        diff_file_moved: Some("#c6a0f6"),
        diff_file_modified: Some("#f5a97f"),
        commit_hash: Some("#b7bdf8"),
        commit_time: Some("#b8c0e0"),
        commit_author: Some("#7dc4e4"),
        danger_fg: Some("#ed8796"),
        push_gauge_bg: Some("#8aadf4"),
        push_gauge_fg: Some("#24273a"),
        tag_fg: Some("#f4dbd6"),
        branch_fg: Some("#8bd5ca")
      )
    '';
  };

  # programs.brave = {
  #   enable = true;
  #   commandLineArgs = [
  #     "--use-gl=angle"
  #     "--use-angle=gl"
  #     "--ozone-platform=wayland"
  #     "--enable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,VaapiVideoDecoder,VaapiIgnoreDriverChecks"
  #   ];
  # };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.zoxide = {
    enable = true;
    enableBashIntegration = false;
  };

  programs.oh-my-posh = {
    enable = true;
    enableBashIntegration = false;
    settings = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile ./files/oh-my-posh.omp.json));
  };

  programs.starship = {
    enable = false;
    enableBashIntegration = false;
  };

  programs.wezterm = {
    enable = true;
    extraConfig = builtins.readFile ./files/wezterm.lua;
  };

  programs.zellij = {
    enable = true;
    settings = {
      #theme = "catppuccin-mocha";
      #mouse_mode = false;
      copy_on_select = true;
      pane_frames = false;
      scroll_buffer_size = 50000;
      # Unbind keys that conflict with Claude Code (keep Ctrl+t for tab mode)
      keybinds = {
        unbind = ["Ctrl p" "Ctrl n" "Ctrl o"];
      };
    };
  };

  programs.keychain = mkIf stdenv.isLinux {
    enable = true;
    enableBashIntegration = false;
    keys = ["id_ed25519"];
  };

  programs.fzf = {
    enable = true;
    enableBashIntegration = false;
  };

  # TODO: conflicts with Cursor
  # programs.bat.enable = true;

  programs.eza.enable = true;
  programs.eza.enableBashIntegration = false;

  # services.syncthing = {
  #   enable = pkgs.stdenv.isLinux;
  # };

  systemd.user.services.rclone-gdrive = mkIf stdenv.isLinux {
    Unit = {
      Description = "Mount Google Drive via rclone";
      After = ["network-online.target"];
    };
    Service = {
      Type = "notify";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/gdrive";
      ExecStart = "${pkgs.rclone}/bin/rclone mount gdrive: %h/gdrive --vfs-cache-mode full --vfs-cache-max-age 72h --dir-cache-time 5m";
      ExecStop = "/run/wrappers/bin/fusermount3 -u %h/gdrive";
      Restart = "on-failure";
      RestartSec = 5;
      Environment = ["PATH=/run/wrappers/bin"];
    };
    Install = {
      WantedBy = ["default.target"];
    };
  };

  systemd.user.services.seafile-cli = mkIf stdenv.isLinux {
    Unit = {
      Description = "Seafile CLI sync daemon";
      After = ["network-online.target"];
    };
    Service = {
      Type = "forking";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/Seafile %h/seafile-client";
      ExecStart = "${pkgs.seafile-shared}/bin/seaf-cli start";
      ExecStop = "${pkgs.seafile-shared}/bin/seaf-cli stop";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install = {
      WantedBy = ["default.target"];
    };
  };

  programs.atuin = {
    enable = true;
    flags = [
      "--disable-up-arrow"
    ];
    enableBashIntegration = false;
  };
}
