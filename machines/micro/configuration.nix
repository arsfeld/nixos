{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ./hardware-configuration.nix
  ];

  services.journald.extraConfig = "SystemMaxUse=1G";

  age.secrets."restic-password".file = ../../secrets/restic-password.age;
  age.secrets."restic-password".mode = "444";

  services.tailscale.enable = true;

  users.users.mox = {
    isSystemUser = true;
    group = "mox";
  };
  users.groups.mox = {};

  systemd.services.mox = {
    enable = true;
    description = "Mox";
    serviceConfig = {
      ExecStart = "${pkgs.mox}/bin/mox serve";
      Restart = "always";
      WorkingDirectory = "/var/lib/mox";
    };
    wantedBy = ["multi-user.target"];
  };

  security.acme.acceptTerms = true;

  services.nginx.defaultSSLListenPort = 8443;
  services.nginx.defaultHTTPListenPort = 8888;

  services.fail2ban = {
    enable = true;
    ignoreIP = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"
    ];
  };

  services.nginx.virtualHosts."webmail.arsfeld.net" = {
    forceSSL = false;
    enableACME = false;
  };

  services.roundcube = {
    enable = true;
    hostName = "webmail.arsfeld.net";
    extraConfig = ''
      # starttls needed for authentication, so the fqdn required to match
      # the certificate
      $config['mail_domain'] = "ssl://micro.arsfeld.net";
      $config['smtp_user'] = "%u";
      $config['smtp_pass'] = "%p";
    '';
  };

  services.restic.backups = {
    micro = {
      paths = [
        "/var/lib"
        "/root"
      ];
      exclude = [
        # very large paths
        "/var/lib/docker"
        "/var/lib/systemd"
        "/var/lib/libvirt"

        "'**/.cache'"
        "'**/.nix-profile'"
      ];
      passwordFile = config.age.secrets."restic-password".path;
      repository = "rest:http://storage:8000/micro";
      initialize = true;
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };

  networking.firewall.enable = false;
  boot.tmp.cleanOnBoot = true;
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];
  networking.hostName = "micro";
}
