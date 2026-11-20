# Weekly `darwin-rebuild switch`, from master on GitHub rather than a local
# checkout, so uncommitted work in ~/Code/nixos never lands by accident. It
# switches home-manager too, which nix-darwin now owns on the Macs (this
# replaced home-manager's own weekly launchd agent).
{
  flake.modules.darwin.mac = {
    config,
    pkgs,
    darwinHost,
    ...
  }: let
    flake = "github:arsfeld/nixos#${darwinHost}";
    log = "/var/log/darwin-auto-update.log";
    script = pkgs.writeShellScript "darwin-auto-update" ''
      export PATH=/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin
      echo "=== $(date) switching to ${flake}"
      if darwin-rebuild switch --refresh --flake ${flake}; then
        echo "=== $(date) done"
      else
        /bin/launchctl asuser "$(id -u ${config.system.primaryUser})" \
          /usr/bin/osascript -e 'display notification "Weekly switch failed, see ${log}" with title "nix-darwin"'
        exit 1
      fi
    '';
  in {
    key = "modules/darwin/auto-update";
    launchd.daemons.darwin-auto-update.serviceConfig = {
      ProgramArguments = ["${script}"];
      # Sundays 10:00. If the Mac is asleep then, launchd runs it on wake.
      StartCalendarInterval = [
        {
          Weekday = 0;
          Hour = 10;
          Minute = 0;
        }
      ];
      StandardOutPath = log;
      StandardErrorPath = log;
      ProcessType = "Background";
    };
  };
}
