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
              IPv4Forwarding = true;
              IPv6Forwarding = true;
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

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = internalInterface;
          listen-address = gatewayIP;
          bind-interfaces = true;

          # DHCP
          dhcp-range = "${ipRangePrefix}10,${ipRangePrefix}254,12h";
          dhcp-option = [
            "option:router,${gatewayIP}"
            "option:dns-server,${gatewayIP}"
          ];

          # DNS
          no-resolv = true;
          server = dnsServers;
          cache-size = 1000;
          domain-needed = true;
          bogus-priv = true;
          dnssec = true;
          trust-anchor = ".,19036,8,2,49AAC11D7B6F6446702E54A1607371607A1A41855200FD2CE1CDDE32F24E8FB5";
        };
      };
    }
