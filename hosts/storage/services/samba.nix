{...}: {
  services.samba-wsdd.enable = true; # make shares visible for windows 10 clients
  networking.firewall.allowedTCPPorts = [
    5357 # wsdd
  ];
  networking.firewall.allowedUDPPorts = [
    3702 # wsdd
  ];
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
      };
    };

    shares = {
      homes = {
        browseable = "no"; # note: each home will be browseable; the "homes" share will not.
        "read only" = "no";
        "guest ok" = "no";
        "follow symlinks" = "yes";
        "wide links" = "yes";
        path = "/home/%S";
      };

      files = {
        path = "/mnt/storage/files";
        browseable = "yes";
        "read only" = "no";
      };

      media = {
        path = "/mnt/storage/media";
        browseable = "yes";
        "read only" = "no";
      };

      media-legacy = {
        path = "/mnt/storage/media";
        browseable = "yes";
        "read only" = "no";
      };

      backups = {
        path = "/mnt/storage/backups";
        browseable = "yes";
        "read only" = "no";
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
        </service-group>
      '';
    };
  };
}
