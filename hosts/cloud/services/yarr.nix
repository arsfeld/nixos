{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  ports = config.mediaServices.ports;
  yarr-overlay = final: prev: {
    yarr = prev.buildGoModule rec {
      pname = "yarr";
      version = "2.4-dev";
      subPackages = ["cmd/yarr"];
      src = pkgs.fetchFromGitHub {
        owner = "nkanaev";
        repo = "yarr";
        rev = "5254df53dc6d6e69b4f043e8d232d05b16ceb548";
        sha256 = "sha256-mJpiSdCNAYpgSLPXg7EO4LIwb8VWS7J2R1xRQrXbtQM=";
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
