{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; {
  networking.firewall.enable = false;
  networking.hostId = "bf276279";

  networking.hostName = "striker";

  networking.useDHCP = false;
  networking.interfaces.enp12s0.useDHCP = true;


  # services.nebula.networks = {
  #   home = {
  #     lighthouses = [
  #       "192.168.100.1"
  #     ];
  #     settings =
  #       {
  #         punchy = {
  #           punch = true;
  #         };
  #       };
  #     firewall = {
  #       outbound =
  #         [
  #           {
  #             host = "any";
  #             port = "any";
  #             proto = "any";
  #           }
  #         ];
  #       inbound =
  #         [
  #           {
  #             host = "any";
  #             port = "any";
  #             proto = "any";
  #           }
  #         ];
  #     };
  #     ca = "/etc/nebula/ca.crt";
  #     cert = "/etc/nebula/striker.crt";
  #     key = "/etc/nebula/striker.key";
  #     staticHostMap = {
  #       "192.168.100.1" = [
  #         "155.248.227.144:4242"
  #       ];
  #     };
  #   };
  # };
}
