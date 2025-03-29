{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  ports = config.media.gateway.ports;
  yarr-overlay = final: prev: {
    yarr = prev.buildGoModule rec {
      pname = "yarr";
      version = "2.5";
      subPackages = ["cmd/yarr"];
      src = pkgs.fetchFromGitHub {
        owner = "nkanaev";
        repo = pname;
        rev = "v${version}";
        sha256 = "sha256-yII0KV4AKIS1Tfhvj588O631JDArnr0/30rNynTSwzk=";
      };

      vendorHash = null;

      ldflags = [
        "-s"
        "-w"
        "-X main.Version=${version}"
        "-X main.GitHash=none"
      ];

      tags = [
        "sqlite_foreign_keys"
        "release"
      ];
    };
  };
in {
  nixpkgs.overlays = [yarr-overlay];

  # Yarr service
  users.users.yarr = {
    group = "yarr";
    isSystemUser = true;
    home = "/var/lib/yarr";
    createHome = true;
  };

  users.groups.yarr = {};

  systemd.services.yarr = {
    description = "Yarr RSS reader";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "yarr";
      Group = "yarr";
      ExecStart = "${pkgs.yarr}/bin/yarr -addr 0.0.0.0:${toString ports.yarr} -db /var/lib/yarr/yarr.db";
      Restart = "on-failure";
      RestartSec = "5s";
      WorkingDirectory = "/var/lib/yarr";
    };
  };
}
