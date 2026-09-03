{
  self,
  inputs,
  system,
}: let
  lib = inputs.nixpkgs.lib;
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  blackbird = self.nixosConfigurations.blackbird.config;
  raider = self.nixosConfigurations.raider.config;
  packageNamed = name: packages:
    lib.any (package: lib.getName package == name) packages;
  enabledExtensions = config:
    lib.concatMap
    (database: database.settings."org/gnome/shell".enabled-extensions or [])
    config.programs.dconf.profiles.user.databases;
  monitorSettings =
    lib.findFirst
    (settings: settings != null)
    null
    (map
      (database: database.settings."org/gnome/shell/extensions/monitor-control" or null)
      blackbird.programs.dconf.profiles.user.databases);
in
  assert blackbird.constellation.desktop.gnome.monitorControl.enable;
  assert blackbird.hardware.i2c.enable;
  assert packageNamed "ddcutil" blackbird.environment.systemPackages;
  assert packageNamed "gnome-shell-extension-monitorcontrol-brightness-and-volume"
  blackbird.environment.systemPackages;
  assert builtins.elem "monitor-control@ahmed-shaalan" (enabledExtensions blackbird);
  assert monitorSettings != null;
  assert monitorSettings.show-brightness;
  assert monitorSettings.show-volume;
  assert monitorSettings.unify-volume;
  assert !raider.constellation.desktop.gnome.monitorControl.enable;
  assert !builtins.elem "monitor-control@ahmed-shaalan" (enabledExtensions raider);
    pkgs.runCommand "blackbird-audio-control-test" {} ''
      touch $out
    ''
