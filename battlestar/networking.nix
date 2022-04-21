{ lib, ... }: {
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  networking = {
    nameservers = [ "213.186.33.99"
 ];
    defaultGateway = "54.39.49.254";
    defaultGateway6 = "";
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce true;
    interfaces = {
      eno3 = {
        ipv4.addresses = [
          { address="54.39.49.189"; prefixLength=24; }
        ];
        ipv6.addresses = [
          { address="fe80::ae1f:6bff:fe64:4fd4"; prefixLength=64; }
        ];
        ipv4.routes = [ { address = "54.39.49.254"; prefixLength = 32; } ];
        # ipv6.routes = [ { address = ""; prefixLength = 128; } ];
      };
      
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="ac:1f:6b:64:4f:d4", NAME="eno3"
    ATTR{address}=="ac:1f:6b:64:4f:d5", NAME="eno4"
  '';
}
