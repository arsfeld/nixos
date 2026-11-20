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
      # "none" until the list is trusted: nothing installed by hand is removed.
      # Switch to "uninstall" to make the list exact.
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
        "rbenv"
        "xcodegen"
        "yoke"
      ];
      casks = [
        "android-platform-tools"
        "android-studio"
        "balenaetcher"
        "brave-browser"
        "cc-switch"
        "claude"
        "crmne/tap/spotifast"
        "cursor"
        "descript"
        "discord"
        "epic-games"
        "firefox"
        "flutter"
        "font-cascadia-code-nf"
        "ghostty"
        "google-chrome"
        "granola"
        "grandperspective"
        "hermes-desktop"
        "iina"
        "iptvnator"
        "iterm2"
        "microsoft-excel"
        "microsoft-onenote"
        "microsoft-outlook"
        "microsoft-powerpoint"
        "microsoft-teams"
        "microsoft-word"
        "multiviewer"
        "netnewswire"
        "obsidian"
        "onedrive"
        "opencode-desktop"
        "orbstack"
        "orion"
        "pearcleaner"
        "plex"
        "postgres-app"
        "private-internet-access"
        "slack"
        "spotify"
        "stats"
        "steam"
        "stremio"
        "sublime-merge"
        "swish"
        "tailscale-app"
        "transmission"
        "visual-studio-code"
        "warp"
        "zed"
        "zen"
        "zoom"
      ];
      # Needs an App Store sign-in on the Mac first. Xcode is left out on
      # purpose: it is huge and installed by hand where it is wanted.
      masApps = {
        "Developer" = 640199958;
        "Infuse" = 1136220934;
        "Reeder" = 6475002485;
        "WhatsApp" = 310633997;
        "WireGuard" = 1451685025;
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
