# Evaluated settings of a host, for hosts whose toplevel must not be evaluated
# (cylon-link: its evaluation builds a cross toolchain). verify.sh applies this
# to nixosConfigurations.<host> with import-from-derivation disabled.
c: let
  cfg = c.config;
  unit = u: {inherit (u) serviceConfig environment script preStart postStart wantedBy after requires;};
in {
  services = builtins.mapAttrs (_: unit) cfg.systemd.services;
  timers = builtins.mapAttrs (_: t: t.timerConfig) cfg.systemd.timers;
  etc = builtins.mapAttrs (_: e: e.text) (c.lib.filterAttrs (_: e: e.text != null) cfg.environment.etc);
  users = builtins.mapAttrs (_: u: {inherit (u) isNormalUser extraGroups;}) cfg.users.users;
  packages = map (p: p.name) cfg.environment.systemPackages;
  firewall = cfg.networking.firewall;
  hostName = cfg.networking.hostName;
}
