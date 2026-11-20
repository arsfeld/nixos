# What every Mac gets. The CLI environment is home/home.nix (wired in by
# modules/flake/darwin.nix); this is the macOS side: apps and defaults.
{
  flake.modules.darwin.mac = {pkgs, ...}: {
    key = "modules/darwin/mac";
    system.stateVersion = 6;
    system.primaryUser = "arosenfeld";
    users.users.arosenfeld.home = "/Users/arosenfeld";

    # Determinate Nix owns the daemon and /etc/nix/nix.conf;
    # inputs.determinate.darwinModules.default turns nix-darwin's own Nix
    # management off for it.

    security.pam.services.sudo_local.touchIdAuth = true;

    # Login shell: fish from here, set once by hand with
    #   chsh -s /run/current-system/sw/bin/fish
    # (users.knownUsers would let nix-darwin manage the whole account).
    programs.fish.enable = true;
    environment.shells = [pkgs.fish];

    # Apps that have no nixpkgs build for darwin, or update themselves. Anything
    # home/home.nix installs (fd, git-lfs, kotlin, node, starship, topgrade,
    # fish) stays out of this list.
    homebrew = {
      enable = true;
      # Install only, never remove: anything installed outside this list
      # (`brew install` by hand, a cask dropped from it) is left alone.
      # "uninstall" would make the list exact, removing everything else.
      onActivation.cleanup = "none";
      taps = [
        "can1357/tap"
        "crmne/tap"
        "mutagen-io/mutagen"
      ];
      brews = [
        "can1357/tap/omp"
        "cmake"
        "cocoapods"
        "git-filter-repo"
        "github-mcp-server"
        "go"
        "imagemagick"
        "jsonnet"
        "k9s"
        "libepoxy"
        "maven"
        "meson"
        "mpv"
        "mutagen-io/mutagen/mutagen"
        "ncdu"
        "oh-my-posh"
        "openai-whisper"
        "opencode"
        "opencv"
        "pkgconf"
        "rbenv"
        "xcodegen"
        "yoke"
      ];
      casks = [
        "android-platform-tools"
        "claude"
        "discord"
        "epic-games"
        "flutter"
        "font-cascadia-code-nf"
        "ghostty"
        "google-chrome"
        "granola"
        "iina"
        "multiviewer"
        "orbstack"
        "postgres-app"
        "spotify"
        "stats"
        "steam"
        "sublime-merge"
        "swish"
        "tailscale-app"
        "zed"
        "zen"
      ];
      # Needs an App Store sign-in on the Mac first. Xcode is left out on
      # purpose: it is huge and installed by hand where it is wanted.
      masApps = {
        "Infuse" = 1136220934;
        "WhatsApp" = 310633997;
      };
    };

    # Taken from the Air's `defaults read` on 2026-11-20.
    system.defaults = {
      dock = {
        tilesize = 64;
        magnification = true;
      };
      finder.FXPreferredViewStyle = "Nlsv";
      NSGlobalDomain = {
        KeyRepeat = 5;
        InitialKeyRepeat = 30;
        AppleInterfaceStyleSwitchesAutomatically = true;
      };
      trackpad = {
        Clicking = true;
        TrackpadThreeFingerDrag = true;
      };
    };
  };
}
