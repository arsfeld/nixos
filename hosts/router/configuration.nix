{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./disko-config.nix
    ./hardware-configuration.nix
    ./interfaces.nix
    ./network.nix
    ./services.nix
    ./traffic-shaping.nix
    ./alerting.nix
    ./ntfy-webhook.nix
    # ./performance-tuning.nix # BBR v3 and TCP optimizations (disabled - may cause issues)
    # ./hardware-offload.nix # TSO/GSO/GRO offloading (disabled - may cause issues)
    # ./loop-protection.nix # Network loop detection and prevention
    # ./xdp-firewall.nix       # XDP DDoS protection (disabled - overkill for home use)
    ../../packages/router_ui/module.nix
  ];

  # Boot configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 2; # Keep only 2 generations

  # Enable IP forwarding and connection tracking
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = false;
    "net.netfilter.nf_conntrack_acct" = true;
  };

  boot.kernelModules = ["nf_conntrack" "wireguard"];

  # Basic networking
  networking = {
    hostName = "router";
    useDHCP = false;
    useNetworkd = true;
    firewall.enable = false;
    nat.enable = false;
  };

  # System packages - minimal set for router functionality
  environment.systemPackages = with pkgs; [
    vim # Keep for editing
    conntrack-tools # Required for client tracking
    jq # Required for parsing nftables output
    speedtest-cli # Required for speed testing
    bc # Required for speed test calculations
    gawk # Required for speed test parsing
  ];

  # Enable SSH
  services.openssh.enable = true;

  # Garbage collection to save disk space
  nix.gc = {
    automatic = true;
    dates = lib.mkForce "weekly"; # Override common module's schedule
    options = lib.mkForce "--delete-older-than 7d"; # Override common module's 30d
  };

  # Optimize nix store regularly
  nix.optimise.automatic = true;

  # Additional Nix settings to minimize disk usage
  nix.settings = {
    auto-optimise-store = true;
    min-free = 100 * 1024 * 1024; # 100MB minimum free space
    max-free = 500 * 1024 * 1024; # 500MB maximum free space
  };

  # Limit journal size
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    SystemKeepFree=50M
    MaxRetentionSec=7day
  '';

  # Minimize documentation
  documentation.enable = false;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  # Disable virtualization to save disk space
  constellation.virtualization.enable = false;
  constellation.netdataClient.enable = false;

  # Enable Podman for containerized services
  constellation.podman.enable = true;

  # System state version
  system.stateVersion = "24.05";

  # Email configuration using constellation module
  constellation.email = {
    enable = true;
    fromEmail = "router-alerts@rosenfeld.one";
    toEmail = "alex@rosenfeld.one"; # Change to your email
  };

  # Enable LLM-powered crash log analysis
  constellation.llmEmail.enable = true;

  # Traffic shaping configuration
  router.trafficShaping = {
    enable = true;

    # WAN shaping - set to 90% of 2.5G symmetric fiber
    wanShaping = {
      bandwidth = 2250; # Upload bandwidth in Mbit/s (90% of 2500)
      ingressBandwidth = 2250; # Download bandwidth in Mbit/s (90% of 2500)
      overhead = "ethernet"; # Fiber uses ethernet framing
      nat = true;
      wash = false; # No need to wash DSCP on fiber
      ackFilter = true; # Still useful for TCP optimization
      flowMode = "triple-isolate"; # Best isolation between flows
      rttMode = "metro"; # Fiber typically has low latency
    };

    # LAN shaping (optional - usually not needed)
    lanShaping = {
      enable = false;
      bandwidth = 1000;
      flowMode = "flows";
      rttMode = "lan";
    };

    # Traffic classification
    classification = {
      enable = true;
      customRules = ''
        # Add custom classification rules here
        # Example: Prioritize specific game server
        # ip daddr 192.168.10.50 udp dport 25565 ip dscp set cs4
      '';
    };

    # QoS monitoring
    monitoring.enable = true; # Enable QoS monitoring
  };

  # Alerting configuration
  router.alerting = {
    enable = true;

    # Email notifications using constellation email module
    emailConfig = {
      enable = true; # Uses constellation email configuration
    };

    # Webhook notifications (Discord, Slack, etc)
    # webhookUrl = "https://discord.com/api/webhooks/YOUR_WEBHOOK_URL";

    # ntfy.sh push notifications (mobile app)
    ntfyUrl = "https://ntfy.sh/arsfeld-router";

    # Alert thresholds
    thresholds = {
      diskUsagePercent = 80; # Alert when disk usage exceeds 80%
      temperatureCelsius = 70; # Alert when temperature exceeds 70°C
      bandwidthMbps = 2000; # Alert when client uses >2Gbps
      cpuUsagePercent = 90; # Alert when CPU usage exceeds 90%
      memoryUsagePercent = 85; # Alert when memory usage exceeds 85%
    };
  };

  # VPN Manager service
  services.vpn-manager = {
    enable = true;
    port = 8501;
    openFirewall = true; # Open port in firewall for local access
  };
}
