{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.miniupnpd-nftables;
  configFile = pkgs.writeText "miniupnpd.conf" ''
    ext_ifname=${cfg.externalInterface}
    enable_natpmp=${
      if cfg.natpmp
      then "yes"
      else "no"
    }
    enable_upnp=${
      if cfg.upnp
      then "yes"
      else "no"
    }

    ${concatMapStrings (range: ''
        listening_ip=${range}
      '')
      cfg.internalIPs}

    ${cfg.appendConfig}
  '';
  firewall =
    if config.networking.nftables.enable
    then "nftables"
    else "iptables";
  miniupnpd = pkgs.miniupnpd-nftables;
  firewalls =
    if config.networking.nftables.enable
    then ["nft"]
    else ["iptables"] ++ lib.optional (config.networking.enableIPv6) "ip6tables";
in {
  options = {
    services.miniupnpd-nftables = {
      enable = mkEnableOption (lib.mdDoc "MiniUPnP daemon");

      externalInterface = mkOption {
        type = types.str;
        description = lib.mdDoc ''
          Name of the external interface.
        '';
      };

      internalIPs = mkOption {
        type = types.listOf types.str;
        example = ["192.168.1.1/24" "enp1s0"];
        description = lib.mdDoc ''
          The IP address ranges to listen on.
        '';
      };

      natpmp = mkEnableOption (lib.mdDoc "NAT-PMP support");

      upnp = mkOption {
        default = true;
        type = types.bool;
        description = lib.mdDoc ''
          Whether to enable UPNP support.
        '';
      };

      appendConfig = mkOption {
        type = types.lines;
        default = "";
        description = lib.mdDoc ''
          Configuration lines appended to the MiniUPnP config.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # pass as env var instead of script argument because nftables scripts dont take arguments
    networking.firewall.extraCommands = builtins.concatStringsSep "\n" (map (fw: ''
        EXTIF=${cfg.externalInterface} ${pkgs.bash}/bin/bash -x ${miniupnpd}/etc/miniupnpd/${fw}_init.sh
      '')
      firewalls);

    networking.firewall.extraStopCommands = builtins.concatStringsSep "\n" (map (fw: ''
        EXTIF=${cfg.externalInterface} ${pkgs.bash}/bin/bash -x ${miniupnpd}/etc/miniupnpd/${fw}_removeall.sh
      '')
      firewalls);

    systemd.services.miniupnpd = {
      description = "MiniUPnP daemon";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        ExecStart = "${miniupnpd}/bin/miniupnpd -f ${configFile}";
        PIDFile = "/run/miniupnpd.pid";
        Type = "forking";
      };
    };
  };
}
