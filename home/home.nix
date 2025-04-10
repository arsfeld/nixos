{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf;
  nvidia-offload = pkgs.writeShellScriptBin "nvidia-offload" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec "$@"
  '';
in {
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home = {
    username = "arosenfeld";
    homeDirectory =
      if stdenv.isLinux
      then "/home/arosenfeld"
      else "/Users/arosenfeld";
    stateVersion = "22.05";
    packages = with pkgs; [
      btop
      bottom
      cachix
      czkawka
      devbox
      devenv
      direnv
      distrobox
      dogdns
      du-dust
      fastfetch
      fd
      fortune
      glances
      htop
      kondo
      nil
      nix
      nvidia-offload
      procs
      ripgrep
      ruby
      rustup
      starship
      tldr
      uv
      vim
      waypipe
      yt-dlp
      zellij

      pnpm
      nodejs
      supabase-cli

      (writeScriptBin "murder" (builtins.readFile ./scripts/murder))
      (writeScriptBin "running" (builtins.readFile ./scripts/running))
    ];
    sessionPath = ["$HOME/.local/bin"];
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

  # Let Home Manager install and manage itself.
  # programs.home-manager.enable = true;

  xdg.configFile."starship.toml" = {
    source = ./files/starship.toml;
  };
  xdg.configFile."htop/htoprc" = {
    source = ./files/htoprc;
  };

  programs.home-manager.enable = true;

  programs.fish = {
    enable = true;
  };

  programs.zsh = {
    enable = true;
    syntaxHighlighting.enable = true;
    prezto = {
      enable = false;
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

    initExtraFirst = ''
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
  };

  programs.oh-my-posh = {
    enable = true;
    settings = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile ./files/oh-my-posh.omp.json));
  };

  programs.starship = {
    enable = false;
    enableZshIntegration = true;
    enableBashIntegration = false;
    enableFishIntegration = true;
  };

  programs.wezterm = {
    enable = true;
    extraConfig = builtins.readFile ./files/wezterm.lua;
  };

  programs.zellij = {
    enable = false;
    settings = {
      theme = "catppuccin-macchiato";
      #mouse_mode = false;
      copy_on_select = false;
    };
  };

  programs.keychain = mkIf stdenv.isLinux {
    enable = true;
    enableZshIntegration = true;
    inheritType = "any-once";
    keys = ["id_ed25519"];
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.bat.enable = true;
  programs.eza.enable = true;
  programs.eza.enableZshIntegration = true;

  # services.syncthing = {
  #   enable = pkgs.stdenv.isLinux;
  # };

  programs.atuin = {
    enable = true;
    flags = [
      "--disable-up-arrow"
    ];
  };

  programs.mangohud = {
    enable = true;
    enableSessionWide = false;
    settings = {
      # full = true;
      # no_display = true;
      # cpu_load_change = true;
      # toggle_fps_limit="F1";
      legacy_layout = false;
      gpu_stats = true;
      gpu_temp = true;
      gpu_load_change = true;
      gpu_load_value = "50,90";
      gpu_load_color = "FFFFFF,FF7800,CC0000";
      gpu_text = "GPU";
      cpu_stats = true;
      cpu_temp = true;
      cpu_load_change = true;
      core_load_change = true;
      cpu_load_value = "50,90";
      cpu_load_color = "FFFFFF,FF7800,CC0000";
      cpu_color = "2e97cb";
      cpu_text = "CPU";
      io_color = "a491d3";
      vram = true;
      vram_color = "ad64c1";
      ram_color = "c26693";
      fps = true;
      engine_color = "eb5b5b";
      gpu_color = "2e9762e";
      wine_color = "eb5b5b";
      frame_timing = 1;
      frametime_color = "00ff00";
      media_player_color = "ffffff";
      background_alpha = 0.4;
      font_size = 24;
      blacklist = "google-chrome,chrome,UplayWebCore,upc";
      background_color = "020202";
      position = "top-left";
      text_color = "ffffff";
      round_corners = 0;
      toggle_hud = "Shift_R+F12";
      toggle_logging = "Shift_L+F2";
      upload_log = "F5";
      output_folder = "/home/arosenfeld";
      media_player_name = "spotify";
    };
  };

  # programs.zsh.shellAliases = {
  #   cat = "${pkgs.bat}/bin/bat";
  # };
}
