{
  pkgs,
  self,
  ...
}: {
  imports =
    self.nixosSuites.cloud
    ++ [
      ./hardware-configuration.nix
      ./services
      ./services.nix
      ./containers.nix
    ];

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  #boot.kernelPackages = pkgs.linuxPackages_latest;

  #services.blocky.settings.customDNS.mapping."arsfeld.one" = "100.118.254.136";
  #services.redis.servers.blocky.bind = "100.66.38.77";
  #services.redis.servers.blocky.port = 6378;

  # systemd.email-notify.mailFrom = "admin@arsfeld.one";
  # systemd.email-notify.mailTo = "arsfeld@gmail.com";

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
}
