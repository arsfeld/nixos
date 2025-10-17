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
        du-dust
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
      ]
      ++ linuxOnlyPkgs; # Added linuxOnlyPkgs
    sessionVariables =
      {
        PNPM_HOME = "$HOME/.local/share/pnpm";
        NPM_CONFIG_PREFIX = "$HOME/.npm-global";
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
      "claude" = "${pkgs.nodejs}/bin/npx -y @anthropic-ai/claude-code@latest";
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

  programs.home-manager.enable = true;

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
    };
  };

  programs.zsh = {
    enable = true;

    prezto = {
      enable = true;
      pmodules = [
        "environment"
        "terminal"
        "editor"
        "history"
        "directory"
        "spectrum"
        "utility"
        "completion"
        "syntax-highlighting"
      ];
    };

    initContent = mkBefore ''
      # nix daemon
      if [[ -s /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
          source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      fi

      # nix single-user
      if [[ -s ~/.nix-profile/etc/profile.d/nix.sh ]]; then
          source ~/.nix-profile/etc/profile.d/nix.sh
      fi

      if [[ -s /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi

      if [[ -s /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
      fi

      if [[ -s $HOME/.cargo/env ]]; then
        source $HOME/.cargo/env
      fi

      # if [[ -z "$ZELLIJ" && "$TERM_PROGRAM" != "vscode" && -n "$SSH_CLIENT" ]]; then
      #   zellij attach -c
      # fi

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

      unsetopt EXTENDED_GLOB
    '';
    profileExtra = ''
      if [[ -s /etc/set-environment ]]; then
        . /etc/set-environment
      fi
    '';
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
    userEmail = "arsfeld@gmail.com";
    userName = "Alexandre Rosenfeld";
    extraConfig = {
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
