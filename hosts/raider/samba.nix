{pkgs, ...}: {
  services.samba-wsdd.enable = true;

  services.samba = {
    enable = true;

    settings = {
      global = {
        "browseable" = true;
        "smb encrypt" = "required";
        "obey pam restrictions" = "yes";
        "unix password sync" = "yes";
        "passwd program" = "${pkgs.shadow}/bin/passwd %u";
        "passwd chat" = "*New*password* %n\n *Retype*new*password* %n\n *password*updated*successfully*";
        "pam password change" = "yes";
        "read only" = "no";
        "writeable" = "yes";
        "vfs objects" = "catia fruit streams_xattr acl_xattr";
        "fruit:aapl" = "yes";
        "fruit:nfs_aces" = "yes";
        "fruit:model" = "MacSamba";
      };

      homes = {
        browseable = "no";
        "guest ok" = "no";
        "follow symlinks" = "yes";
        "wide links" = "yes";
        path = "/home/%S";
      };

      games = {
        path = "/mnt/games";
        "valid users" = "arosenfeld";
        public = "no";
        writeable = "yes";
      };
    };
  };

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
