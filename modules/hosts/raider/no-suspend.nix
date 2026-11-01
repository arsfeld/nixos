# No suspend: logind ignores, masked sleep units, power management, the noIdleSuspend dconf databases.
{
  configurations.nixos.raider.module = {lib, ...}: {
    # Disable suspend/hibernate
    services.logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchDocked = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandlePowerKey = "ignore";
      HandleSuspendKey = "ignore";
      HandleHibernateKey = "ignore";
      IdleAction = "ignore";
      IdleActionSec = 0;
    };

    # Mask the sleep units entirely: any Suspend() DBus call (desktop session,
    # GDM greeter, systemctl) fails instead of sleeping. logind IdleAction=ignore
    # and the dconf policies below don't cover every caller.
    systemd.services = {
      systemd-suspend.enable = false;
      systemd-hibernate.enable = false;
      systemd-hybrid-sleep.enable = false;
      systemd-suspend-then-hibernate.enable = false;
    };
    systemd.targets = {
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
      sleep.enable = false;
    };

    # Disable power management features
    powerManagement = {
      enable = true;
      powertop.enable = false; # Disabled - causes aggressive power management that freezes input
    };

    # Stop gnome-settings-daemon from issuing an idle Suspend() DBus call after
    # 15 min. The masked targets above already make it fail, but logind still
    # broadcasts "The system will suspend now!" before refusing. Locked, so a
    # per-user value can't bring it back. `user` covers the desktop session and
    # the LightDM greeter (user `lightdm`), `gdm` the GNOME variant's greeter.
    programs.dconf.profiles = let
      noIdleSuspend = {
        settings."org/gnome/settings-daemon/plugins/power" = {
          sleep-inactive-ac-type = "nothing";
          sleep-inactive-ac-timeout = lib.gvariant.mkInt32 0;
          sleep-inactive-battery-type = "nothing";
          sleep-inactive-battery-timeout = lib.gvariant.mkInt32 0;
        };
        locks = [
          "/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type"
          "/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout"
          "/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type"
          "/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout"
        ];
      };
    in {
      user.databases = [noIdleSuspend];
      gdm.databases = [noIdleSuspend];
    };
  };
}
