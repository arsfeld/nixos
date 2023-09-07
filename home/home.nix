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
    '';
    profileExtra = ''
      if [[ -s /etc/set-environment ]]; then
        . /etc/set-environment
      fi
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

  programs.zellij.enable = true;

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

  services.syncthing = {
    enable = pkgs.stdenv.isLinux;
  };

  programs.zsh.shellAliases = {
    cat = "${pkgs.bat}/bin/bat";
  };
}
