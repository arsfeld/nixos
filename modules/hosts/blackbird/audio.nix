# Audio: pipewire, EasyEffects presets and autoload files, legacy cleanup, user service.
{
  configurations.nixos.blackbird.module = {pkgs, ...}: {
    # Audio enhancements for G14 speakers
    # EasyEffects will be configured in home-manager with G14-specific presets
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    home-manager.users.arosenfeld.xdg.dataFile = {
      "easyeffects/output/ASUS_G14_2020.json".source = ./easyeffects-blackbird-preset.json;
      "easyeffects/output/No_Effects.json".source = ./easyeffects-no-effects-preset.json;

      "easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json".text = builtins.toJSON {
        device = "alsa_output.pci-0000_04_00.6.analog-stereo";
        "device-description" = "Ryzen HD Audio Controller Analog Stereo";
        "device-profile" = "Speakers";
        "preset-name" = "ASUS_G14_2020";
      };

      "easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json".text = builtins.toJSON {
        device = "alsa_output.pci-0000_01_00.1.hdmi-stereo";
        "device-description" = "TU116 High Definition Audio Controller Digital Stereo (HDMI)";
        "device-profile" = "HDMI / DisplayPort";
        "preset-name" = "No_Effects";
      };
    };

    # Remove only the obsolete, root-owned EasyEffects files created by older
    # versions of this configuration. Preserve the settings database and any
    # unrelated user files.
    system.activationScripts.easyeffectsLegacyCleanup.text = ''
      ${pkgs.coreutils}/bin/rm -f \
        /home/arosenfeld/.config/easyeffects/autoload/output/ASUS_G14_2020.json \
        /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json \
        /home/arosenfeld/.config/easyeffects/settings.json

      ${pkgs.coreutils}/bin/rmdir --ignore-fail-on-non-empty \
        /home/arosenfeld/.config/easyeffects/autoload/output \
        /home/arosenfeld/.config/easyeffects/autoload \
        /home/arosenfeld/.config/easyeffects/output \
        /home/arosenfeld/.config/easyeffects 2>/dev/null || true
    '';

    # Auto-start EasyEffects as a user service
    systemd.user.services.easyeffects = {
      description = "EasyEffects Audio Enhancement";
      wantedBy = ["graphical-session.target"];
      partOf = ["graphical-session.target"];
      after = ["graphical-session.target" "pipewire.service" "wireplumber.service"];
      wants = ["pipewire.service" "wireplumber.service"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.easyeffects}/bin/easyeffects --gapplication-service";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
