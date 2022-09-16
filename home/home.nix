{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs) stdenv;
  inherit (lib) mkIf;
in {
  imports = [
    ./vscode-ssh-fix.nix
  ];

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "arosenfeld";
  home.homeDirectory = "/home/arosenfeld";

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
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
    (writeScriptBin "murder" (builtins.readFile ./scripts/murder))
    (writeScriptBin "running" (builtins.readFile ./scripts/running))
  ];

  services.vscode-ssh-fix.enable = true;

  #services.vscode-server.enable = true;

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "22.05";

  # Let Home Manager install and manage itself.
  # programs.home-manager.enable = true;

  xdg.configFile."starship.toml" = {
    source = ./pastel.toml;
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

  programs.keychain = mkIf stdenv.isLinux {
    enable = true;
    enableZshIntegration = true;
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
}
