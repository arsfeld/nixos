{
  config,
  pkgs,
  lib,
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
      vim
      btop
      htop
      nix
      cachix
      fortune
      distrobox
      neofetch
      direnv
      ruby
      starship
      rnix-lsp
      kondo
      fd
      ripgrep
      procs
      du-dust
      zellij
      rustup
      dogdns
      tldr
      nvidia-offload
      nil
      devbox
      (writeScriptBin "murder" (builtins.readFile ./scripts/murder))
      (writeScriptBin "running" (builtins.readFile ./scripts/running))
    ];
    sessionPath = ["$HOME/.local/bin"];
  };

  # Let Home Manager install and manage itself.
  # programs.home-manager.enable = true;

  xdg.configFile."starship.toml" = {
    source = ./files/pastel.toml;
  };
  xdg.configFile."htop/htoprc" = {
    source = ./files/htoprc;
  };

  programs.home-manager.enable = true;

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
        "command-not-found"
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

      if [[ -s $HOME/.cargo/env ]]; then
        source $HOME/.cargo/env
      fi

      if [[ -z "$ZELLIJ" && "$TERM_PROGRAM" != "vscode" && -n "$SSH_CLIENT" ]]; then
        zellij attach -c
      fi
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
    delta.enable = true;
    userEmail = "arsfeld@gmail.com";
    userName = "Alexandre Rosenfeld";
    extraConfig = {
      credential = {
        helper = "store";
      };
    };
  };

  programs.topgrade.enable = true;

  programs.gitui.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.zoxide = {
    enable = true;
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
  };

  programs.zellij = {
    enable = true;
    settings = {
      theme = "dracula";
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
  programs.eza.enableAliases = true;

  programs.command-not-found.enable = true;

  # services.syncthing = {
  #   enable = pkgs.stdenv.isLinux;
  # };

  programs.mangohud = {
    enable = true;
    enableSessionWide = true;
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
      blacklist = "google-chrome,chrome";
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

  programs.zsh.shellAliases = {
    cat = "${pkgs.bat}/bin/bat";
  };
}
