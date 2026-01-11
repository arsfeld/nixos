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
    ./neovim.nix
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
        dogdns
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
        (writeScriptBin "claude" ''
          #!/usr/bin/env bash
          exec ${pkgs.bun}/bin/bun x @anthropic-ai/claude-code@latest "$@"
        '')
        bun
      ]
      ++ linuxOnlyPkgs; # Added linuxOnlyPkgs
    sessionVariables =
      {
        PNPM_HOME = "$HOME/.local/share/pnpm";
        NPM_CONFIG_PREFIX = "$HOME/.npm-global";
        CLAUDE_NTFY_TOPIC = "arosenfeld-claude";
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
    settings =
      {
        builders-use-substitutes = true;
      }
      // (lib.optionalAttrs (osConfig != null && osConfig.networking.hostName != "cloud") {
        # Use remote builders configuration (skip on cloud to avoid circular dependency)
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

  # Claude Code settings with notification hooks
  home.file.".claude/settings.json".text = builtins.toJSON {
    model = "claude-opus-4-5-20251101";
    includeCoAuthoredBy = false;
    hooks = {
      PreToolUse = [
        {
          matcher = "AskUserQuestion";
          hooks = [
            {
              type = "command";
              command = "${claude-notify}/bin/claude-notify question arosenfeld-claude";
            }
          ];
        }
      ];
    };
  };

  # Claude Code commands
  home.file.".claude/commands/commit.md".source = ./files/claude-commands/commit.md;
  home.file.".claude/commands/release.md".source = ./files/claude-commands/release.md;

  programs.home-manager.enable = true;

  # Set default applications for XDG MIME types
  xdg.mimeApps = {
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
      # Add npm global bin to PATH
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

  programs.atuin = {
    enable = true;
    flags = [
      "--disable-up-arrow"
    ];
    enableBashIntegration = false;
  };

  programs.mangohud = mkIf stdenv.isLinux {
    enable = false;
    enableSessionWide = false;
    settings = {
      # Minimal display configuration for FPS and essential stats
      legacy_layout = false;

      # FPS Display
      fps = true;
      fps_limit = "0";
      frame_timing = 1;
      frametime_color = "00ff00";

      # GPU Stats (minimal)
      gpu_stats = true;
      gpu_temp = true;
      gpu_load_change = false;
      gpu_text = "GPU";
      gpu_color = "2e9762";

      # CPU Stats (minimal)
      cpu_stats = true;
      cpu_temp = true;
      cpu_load_change = false;
      cpu_text = "CPU";
      cpu_color = "2e97cb";

      # Memory Stats (minimal)
      vram = true;
      vram_color = "ad64c1";
      ram = true;
      ram_color = "c26693";

      # Display Configuration
      position = "top-left";
      font_size = 18;
      width = 0;
      height = 0;
      offset_x = 10;
      offset_y = 10;

      # Visual Style (subtle)
      background_alpha = 0.3;
      background_color = "020202";
      text_color = "ffffff";
      round_corners = 5;

      # Toggles
      toggle_hud = "Shift_R+F12";
      toggle_fps_limit = "Shift_L+F1";
      toggle_logging = "Shift_L+F2";
      upload_log = "F5";
      output_folder = "/home/arosenfeld";

      # Extensive blacklist to prevent showing in non-game apps
      blacklist = lib.concatStringsSep "," [
        # Web Browsers
        "google-chrome"
        "chrome"
        "chromium"
        "firefox"
        "firefox-esr"
        "brave"
        "brave-browser"
        "vivaldi"
        "opera"
        "edge"
        "microsoft-edge"
        "safari"
        "epiphany"
        "midori"
        "qutebrowser"
        "nyxt"

        # Electron Apps & Development Tools
        "code"
        "vscode"
        "vscodium"
        "code-oss"
        "atom"
        "sublime_text"
        "brackets"
        "notepadqq"
        "gedit"
        "kate"
        "emacs"
        "vim"
        "nvim"
        "idea"
        "webstorm"
        "pycharm"
        "android-studio"
        "eclipse"

        # 3D Modeling & Graphics Software
        "blender"
        "maya"
        "3dsmax"
        "cinema4d"
        "houdini"
        "modo"
        "substance"
        "zbrush"
        "mudbox"
        "fusion360"
        "autocad"
        "sketchup"
        "freecad"
        "openscad"
        "solvespace"

        # Video & Streaming
        "obs"
        "obs-studio"
        "vlc"
        "mpv"
        "mplayer"
        "celluloid"
        "kodi"
        "plex"
        "jellyfin"
        "youtube"
        "netflix"
        "twitch"

        # Communication
        "discord"
        "Discord"
        "teams"
        "slack"
        "telegram"
        "signal"
        "element"
        "riot"
        "zoom"
        "skype"
        "mumble"
        "teamspeak"

        # Office & Productivity
        "libreoffice"
        "openoffice"
        "onlyoffice"
        "wps"
        "freeoffice"
        "thunderbird"
        "evolution"
        "kmail"
        "geary"
        "mailspring"

        # File Managers & System Tools
        "nautilus"
        "dolphin"
        "thunar"
        "pcmanfm"
        "nemo"
        "caja"
        "ranger"
        "mc"
        "vifm"
        "nnn"
        "terminal"
        "konsole"
        "gnome-terminal"
        "kitty"
        "alacritty"
        "wezterm"
        "foot"
        "terminator"

        # Game Launchers and Stores (show only in actual games)
        "steam"
        "Steam"
        "steamwebhelper"
        "epic"
        "EpicGamesLauncher"
        "uplay"
        "UplayWebCore"
        "upc"
        "origin"
        "Origin"
        "battle.net"
        "Battle.net"
        "gog"
        "GOG Galaxy"
        "itch"
        "lutris"
        "heroic"
        "legendary"
        "rare"
        "bottles"
        "playonlinux"

        # Multimedia Creation
        "gimp"
        "krita"
        "inkscape"
        "darktable"
        "rawtherapee"
        "kdenlive"
        "openshot"
        "shotcut"
        "davinci"
        "resolve"
        "audacity"
        "ardour"
        "lmms"
        "fl_studio"
        "ableton"

        # Other Applications
        "spotify"
        "Spotify"
        "rhythmbox"
        "clementine"
        "amarok"
        "gwenview"
        "eog"
        "feh"
        "sxiv"
        "nomacs"
        "digikam"
        "virtualbox"
        "vmware"
        "qemu"
        "virt-manager"
      ];
    };
  };

  # programs.zsh.shellAliases = {
  #   cat = "${pkgs.bat}/bin/bat";
  # };
}
