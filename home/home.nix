{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf;
in {
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home = {
    username = "arosenfeld";
    homeDirectory = "/home/arosenfeld";
    stateVersion = "22.05";
    packages = with pkgs; [
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
      (writeScriptBin "murder" (builtins.readFile ./scripts/murder))
      (writeScriptBin "running" (builtins.readFile ./scripts/running))
    ];
    sessionPath = ["$HOME/.local/bin"];
  };

  # services.vscode-ssh-fix.enable = pkgs.stdenv.isLinux;

  #services.vscode-server.enable = true;

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
  };

  programs.bash.enable = true;

  programs.git = {
    enable = true;
    delta.enable = true;
    userEmail = "arsfeld@gmail.com";
    userName = "Alexandre Rosenfeld";
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
    inheritType = "any";
    keys = ["id_ed25519"];
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.bat.enable = true;
  programs.exa.enable = true;
  programs.exa.enableAliases = true;

  programs.command-not-found.enable = true;

  services.syncthing = {
    enable = pkgs.stdenv.isLinux;
  };

  programs.zsh.shellAliases = {
    cat = "${pkgs.bat}/bin/bat";
  };
}
