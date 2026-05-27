{...}: {
  services.samba-wsdd.enable = true; # make shares visible for windows 10 clients
  networking.firewall.allowedTCPPorts = [
    5357 # wsdd
  ];
  networking.firewall.allowedUDPPorts = [
    3702 # wsdd
  ];

  users.users.time-machine = {
    isSystemUser = true;
    group = "time-machine";
    home = "/mnt/storage/backups/Time Machine";
  };

  users.groups.time-machine = {};

  services.samba = {
    enable = true;

    # This adds to the [global] section:
    settings = {
      global = {
        "browseable" = true;
        "smb encrypt" = "required";
        "dos charset" = "cp932";
        "unix charset" = "utf-8";
        "display charset" = "utf-8";
        "read only" = "no";
        "writeable" = "yes";
        "vfs objects" = "catia fruit streams_xattr acl_xattr";

        "fruit:aapl" = "yes";
        "fruit:nfs_aces" = "yes";
        "fruit:copyfile" = "no";
        "fruit:model" = "MacSamba";
      };

      homes = {
        browseable = "no"; # note: each home will be browseable; the "homes" share will not.
        "guest ok" = "no";
        "follow symlinks" = "yes";
        "wide links" = "yes";
        path = "/home/%S";
      };

      files = {
        path = "/mnt/storage/files";
      };

      media = {
        path = "/mnt/storage/media";
      };

      backups = {
        path = "/mnt/storage/backups";
      };

      "Time Capsule" = {
        path = "/mnt/storage/backups/Time Machine";
        "valid users" = "arosenfeld";
        public = "no";
        writeable = "yes";

        # Time Machine
        "fruit:delete_empty_adfiles" = "yes";
        "fruit:time machine" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:posix_rename" = "yes";
        "fruit:metadata" = "stream";
      };
    };
  };

  # mDNS
  #
  # This part may be optional for your needs, but I find it makes browsing in Dolphin easier,
  # and it makes connecting from a local Mac possible.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      hinfo = true;
      userServices = true;
      workstation = true;
    };
    extraServiceFiles = {
      smb = ''
        <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>

         <service>
          <type>_adisk._tcp</type>
          <txt-record>sys=waMa=0,adVF=0x100</txt-record>
          <txt-record>dk0=adVN=Time Capsule,adVF=0x82</txt-record>
         </service>

         <service>
          <type>_device-info._tcp</type>
          <txt-record>model=TimeCapsule8,119</txt-record>
        </service>
        </service-group>
      '';
    };
  };
}
