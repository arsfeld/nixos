{
  self,
  inputs,
  system,
}: let
  lib = inputs.nixpkgs.lib;
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  blackbird = self.nixosConfigurations.blackbird.config;
  blackbirdHome = blackbird.home-manager.users.arosenfeld;
  easyEffectsFiles = blackbirdHome.xdg.dataFile;
  speakerAutoload =
    builtins.fromJSON
    easyEffectsFiles."easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json".text;
  monitorAutoload =
    builtins.fromJSON
    easyEffectsFiles."easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json".text;
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

  # blackbird runs Pantheon, where the GNOME settings asserted below are inert
  # but kept for the switch back (hosts/blackbird/configuration.nix). They hold
  # only while that variant is actually selected, and all of them fall with it:
  # the i2c module, ddcutil, the monitor-control extension and its dconf
  # database are set inside the module's `variant == "gnome"` branch.
  gnome = blackbird.constellation.desktop.variant == "gnome";
in
  assert !gnome || blackbird.constellation.desktop.gnome.monitorControl.enable;
  assert !gnome || blackbird.hardware.i2c.enable;
  assert !gnome || packageNamed "ddcutil" blackbird.environment.systemPackages;
  assert !gnome
  || packageNamed "gnome-shell-extension-monitorcontrol-brightness-and-volume"
  blackbird.environment.systemPackages;
  assert !gnome || builtins.elem "monitor-control@ahmed-shaalan" (enabledExtensions blackbird);
  assert !gnome || monitorSettings != null;
  assert !gnome || monitorSettings.show-brightness;
  assert !gnome || monitorSettings.show-volume;
  assert !gnome || builtins.elem "monitor@astraext.github.io" (enabledExtensions blackbird);
  # Vitals is rejected deliberately on GNOME; under Pantheon it is simply absent.
  assert !builtins.elem "Vitals@CoreCoding.com" (enabledExtensions blackbird);
  assert easyEffectsFiles ? "easyeffects/output/ASUS_G14_2020.json";
  assert easyEffectsFiles ? "easyeffects/output/No_Effects.json";
  assert easyEffectsFiles ? "easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json";
  assert easyEffectsFiles ? "easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json";
  assert speakerAutoload.device == "alsa_output.pci-0000_04_00.6.analog-stereo";
  assert speakerAutoload."device-description" == "Ryzen HD Audio Controller Analog Stereo";
  assert speakerAutoload."device-profile" == "Speakers";
  assert speakerAutoload."preset-name" == "ASUS_G14_2020";
  assert monitorAutoload.device == "alsa_output.pci-0000_01_00.1.hdmi-stereo";
  assert monitorAutoload."device-description" == "TU116 High Definition Audio Controller Digital Stereo (HDMI)";
  assert monitorAutoload."device-profile" == "HDMI / DisplayPort";
  assert monitorAutoload."preset-name" == "No_Effects";
  assert builtins.elem "wireplumber.service" blackbird.systemd.user.services.easyeffects.after;
  assert builtins.elem "pipewire.service" blackbird.systemd.user.services.easyeffects.wants;
  assert builtins.elem "wireplumber.service" blackbird.systemd.user.services.easyeffects.wants;
  assert !(blackbird.system.activationScripts ? setupEasyEffectsG14);
  assert blackbird.system.activationScripts ? easyeffectsLegacyCleanup;
    pkgs.runCommand "blackbird-audio-control-test" {} ''
      touch $out
    ''
