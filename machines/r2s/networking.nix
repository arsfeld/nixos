{
  internalInterface,
  externalInterface,
  ipRange ? "192.168.2.0/24",
  dnsServers ? ["8.8.8.8" "8.8.4.4"],
}:
with import ./helpers.nix;
  if !testIpRange ipRange
  then throw ''ipRange '${ipRange}' is invalid. Here is a valid example: 192.168.2.0/24''
  else let
    ipRangePrefix = getIPRangePrefix ipRange;
    gatewayIP = ipRangePrefix + "1";
  in
    {...}: {
      networking.nat.enable = true;
      networking.nat.internalIPs = [ipRange];
      networking.nat.externalInterface = externalInterface;

      systemd.network = {
        enable = true;

        wait-online.anyInterface = true;

        networks = {
          # Connect the bridge ports to the bridge
          "30-lan" = {
            matchConfig.Name = internalInterface;
            address = [
              "${gatewayIP}/24"
            ];
            networkConfig = {
              ConfigureWithoutCarrier = true;
            };
            linkConfig.RequiredForOnline = "no";
          };
          "10-wan" = {
            matchConfig.Name = "${externalInterface}";
            networkConfig = {
              # start a DHCP Client for IPv4 Addressing/Routing
              DHCP = "ipv4";
              # accept Router Advertisements for Stateless IPv6 Autoconfiguraton (SLAAC)
              IPv6AcceptRA = true;
              DNSOverTLS = true;
              DNSSEC = true;
              IPv6PrivacyExtensions = false;
              IPForward = true;
            };
            cakeConfig = {
              Bandwidth = "500M";
              CompensationMode = "ptm";
              OverheadBytes = 8;
            };
            # make routing on this interface a dependency for network-online.target
            linkConfig.RequiredForOnline = "routable";
          };
        };
      };

      services.kea = {
        dhcp4 = {
          enable = true;
          settings = {
            interfaces-config = {
              interfaces = [
                internalInterface
              ];
            };
            lease-database = {
              name = "/var/lib/kea/dhcp4.leases";
              persist = true;
              type = "memfile";
            };
            rebind-timer = 2000;
            renew-timer = 1000;
            subnet4 = [
              {
                pools = [
                  {
                    pool = "${ipRangePrefix + "10"} - ${ipRangePrefix + "254"}";
                  }
                ];
                subnet = ipRange;
                "option-data" = [
                  {
                    "name" = "routers";
                    "data" = gatewayIP;
                  }
                  {
                    "name" = "domain-name-servers";
                    "data" = gatewayIP;
                  }
                ];
              }
            ];
            valid-lifetime = 4000;
          };
        };
      };
    }
