{...}: {
  imports = [
    ./hardware-configuration.nix
    ../../common/acme.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ../../common/sites/arsfeld.one.nix
    ../../common/sites/rosenfeld.one.nix
    ../../common/sites/rosenfeld.blog.nix
    ../../common/sites/arsfeld.dev.nix
    ./services.nix
    ./containers.nix
    ./backup.nix
  ];

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  boot.tmp.cleanOnBoot = true;
  networking.hostName = "cloud";
  networking.firewall.enable = false;
  # This should be overriden by tailscale at some point
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];

  services.fail2ban = {
    enable = true;
    ignoreIP = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"
    ];
  };

  security.acme.certs."arsfeld.dev" = {
    extraDomainNames = ["*.arsfeld.dev"];
  };

  mailserver = {
    enable = false;
    fqdn = "mail.arsfeld.dev";
    domains = ["arsfeld.dev"];

    vmailUID = 5005;

    # A list of all login accounts. To create the password hashes, use
    # nix-shell -p mkpasswd --run 'mkpasswd -sm bcrypt'
    loginAccounts = {
      "alex@arsfeld.dev" = {
        hashedPassword = "$6$Csmhna5YUVoHnZ/S$lrSk0wko.Z/oL.Omf2jAdLc/mSpZsrw8sOXlknmfdHEjMopP7hESNk9PCArGBnZKm566Fo2QoubQWt0SLjbng.";

        aliases = ["postmaster@arsfeld.dev"];
      };
    };

    certificateScheme = "acme";
  };

  services.atticd = {
    enable = true;

    # Replace with absolute path to your credentials file
    credentialsFile = "/etc/atticd.env";

    settings = {
      listen = "[::]:8080";
      chunking = {
        # The minimum NAR size to trigger chunking
        #
        # If 0, chunking is disabled entirely for newly-uploaded NARs.
        # If 1, all NARs are chunked.
        nar-size-threshold = 64 * 1024; # 64 KiB

        # The preferred minimum size of a chunk, in bytes
        min-size = 16 * 1024; # 16 KiB

        # The preferred average size of a chunk, in bytes
        avg-size = 64 * 1024; # 64 KiB

        # The preferred maximum size of a chunk, in bytes
        max-size = 256 * 1024; # 256 KiB
      };
    };
  };
}
