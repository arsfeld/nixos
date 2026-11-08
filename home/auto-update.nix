# Weekly home-manager switch on macOS, from master on GitHub rather than the
# local checkout, so uncommitted work in ~/Code/nixos never lands by accident.
# The Linux hosts get home-manager through their NixOS deploys instead.
{
  config,
  lib,
  pkgs,
  ...
}: let
  flake = "github:arsfeld/nixos#arosenfeld";
  hm = "${config.programs.home-manager.package}/bin/home-manager";
  script = pkgs.writeShellScript "home-manager-auto-update" ''
    export PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin:$PATH
    echo "=== $(date) switching to ${flake}"
    if ${hm} switch --refresh --flake ${flake}; then
      echo "=== $(date) done"
    else
      /usr/bin/osascript -e 'display notification "Weekly switch failed, see ~/Library/Logs/home-manager-auto-update.log" with title "home-manager"'
      exit 1
    fi
  '';
in {
  config = lib.mkIf pkgs.stdenv.isDarwin {
    launchd.agents.home-manager-auto-update = {
      enable = true;
      config = {
        ProgramArguments = ["${script}"];
        # Sundays 10:00. If the Mac is asleep then, launchd runs it on wake.
        StartCalendarInterval = [
          {
            Weekday = 0;
            Hour = 10;
            Minute = 0;
          }
        ];
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/home-manager-auto-update.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/home-manager-auto-update.log";
        ProcessType = "Background";
      };
    };
  };
}
