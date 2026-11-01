# Power: GNOME/Pantheon gsettings overrides, power-profiles-daemon, logind lid/power-key suspend.
{
  configurations.nixos.blackbird.module = {...}: let
    gsettingsOverrides = ''
      [org.gnome.desktop.interface]
      text-scaling-factor=1.25

      [org.gnome.settings-daemon.plugins.power]
      sleep-inactive-ac-type='nothing'
      sleep-inactive-battery-type='nothing'
    '';
  in {
    # Display scaling for high-DPI laptop screen.
    # sleep-inactive-*-type='nothing' works around gsd-power bug
    # https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/issues/903 (fixed in
    # gsd 50, not yet in nixpkgs). On NVIDIA-hybrid laptops the VT switch during
    # resume makes gsd-power store "sleep" as previous_idle_mode and re-suspend
    # ~15s after wake. Lid/power-button suspend still works via logind below.
    #
    # Set for both desktops: Pantheon runs the same gsd-power but compiles its
    # schema overrides from its own option, so the GNOME one alone is inert there
    # -- which silently re-enabled the 15-minute idle suspend when blackbird
    # moved to Pantheon.
    services.desktopManager.gnome.extraGSettingsOverrides = gsettingsOverrides;
    services.desktopManager.pantheon.extraGSettingsOverrides = gsettingsOverrides;

    # Fedora-on-ASUS power management: plain power-profiles-daemon (NOT
    # tuned-ppd). The asus-linux.org Fedora guide explicitly tells G14 owners to
    # `dnf swap tuned-ppd power-profiles-daemon` because tuned-ppd's tuned
    # profiles fight asusd over platform_profile, making the GNOME slider snap
    # back to Balanced within ~40ms. PPD writes platform_profile + amd_pstate
    # EPP directly (no tuned in the middle); asusd reacts via inotify to apply
    # the matching fan curve. Pairs with amd_pstate=active in kernelParams.
    services.power-profiles-daemon.enable = true;

    # Plain S3 suspend for lid close and power key -- deliberately NOT
    # suspend-then-hibernate. Two reasons: (1) the 16 GiB swap is smaller than
    # RAM (22 GiB), so hibernate could fail under memory pressure; (2) s2h on
    # NVIDIA Optimus is unreliable upstream (the inner suspend->hibernate
    # transition often doesn't drive the nvidia path). Plain suspend is the
    # rock-solid option and a laptop is rarely off long enough for hibernate to
    # matter.
    #
    # No IdleAction: GNOME's gsd-power idle suspend (nixpkgs#336723) misfires on
    # NVIDIA-hybrid resume, so both auto-idle paths stay disabled; suspend is
    # triggered only by lid or power key via logind.
    services.logind.settings.Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "suspend";
      HandlePowerKey = "suspend";
    };
  };
}
