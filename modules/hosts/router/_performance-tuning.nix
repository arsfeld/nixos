# High-performance network tuning for router
# Implements BBR v3, advanced TCP optimization, and kernel tuning
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Enable BBR congestion control (v3 if available, v2 fallback)
  boot.kernel.sysctl = {
    # TCP Congestion Control - BBR for lower latency and better throughput
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq"; # Fair Queue works best with BBR

    # Enable ECN (Explicit Congestion Notification) for BBR
    "net.ipv4.tcp_ecn" = 2; # Enable ECN when requested by route
    "net.ipv4.tcp_ecn_fallback" = 1; # Fallback if ECN blackhole detected

    # TCP Fast Open - reduce latency for repeat connections
    "net.ipv4.tcp_fastopen" = 3; # Enable for both client and server
    "net.ipv4.tcp_fastopen_blackhole_timeout_sec" = 0; # Disable blackhole detection

    # TCP Timestamps and SACK for better loss recovery
    "net.ipv4.tcp_timestamps" = 1;
    "net.ipv4.tcp_sack" = 1;
    "net.ipv4.tcp_dsack" = 1;
    "net.ipv4.tcp_fack" = 1; # Forward Acknowledgment

    # TCP Memory Tuning for Gigabit+ speeds
    # Format: min default max (in bytes)
    "net.ipv4.tcp_rmem" = "4096 131072 134217728"; # 128MB max receive buffer
    "net.ipv4.tcp_wmem" = "4096 65536 134217728"; # 128MB max send buffer

    # Core Network Memory Settings
    "net.core.rmem_default" = 26214400; # 25MB default receive buffer
    "net.core.rmem_max" = 134217728; # 128MB max receive buffer
    "net.core.wmem_default" = 26214400; # 25MB default send buffer
    "net.core.wmem_max" = 134217728; # 128MB max send buffer
    "net.core.optmem_max" = 65536; # Option memory buffer

    # Network Device Settings for High Performance
    "net.core.netdev_max_backlog" = 30000; # Increase input queue size
    "net.core.netdev_budget" = 600; # Increase budget for packet processing
    "net.core.netdev_budget_usecs" = 2000; # Time for packet processing

    # UDP Tuning for QUIC and VPN traffic
    "net.ipv4.udp_rmem_min" = 8192;
    "net.ipv4.udp_wmem_min" = 8192;
    "net.ipv4.udp_mem" = "102400 873800 16777216";

    # Connection Tracking Optimization
    "net.netfilter.nf_conntrack_max" = 1048576; # 1M connections
    "net.netfilter.nf_conntrack_tcp_timeout_established" = 3600; # 1 hour
    "net.netfilter.nf_conntrack_tcp_timeout_time_wait" = 60;
    "net.netfilter.nf_conntrack_tcp_timeout_close_wait" = 60;
    "net.netfilter.nf_conntrack_tcp_timeout_fin_wait" = 60;
    "net.netfilter.nf_conntrack_udp_timeout" = 30;
    "net.netfilter.nf_conntrack_udp_timeout_stream" = 180;

    # Enable IP forwarding optimizations
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv4.conf.default.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;

    # ARP and Neighbor Cache
    "net.ipv4.neigh.default.gc_thresh1" = 2048;
    "net.ipv4.neigh.default.gc_thresh2" = 4096;
    "net.ipv4.neigh.default.gc_thresh3" = 8192;
    "net.ipv6.neigh.default.gc_thresh1" = 2048;
    "net.ipv6.neigh.default.gc_thresh2" = 4096;
    "net.ipv6.neigh.default.gc_thresh3" = 8192;

    # TCP Optimization for Low Latency
    "net.ipv4.tcp_low_latency" = 1;
    "net.ipv4.tcp_no_metrics_save" = 1; # Don't cache metrics
    "net.ipv4.tcp_moderate_rcvbuf" = 1; # Auto-tune receive buffer
    "net.ipv4.tcp_autocorking" = 0; # Disable auto-corking for lower latency

    # TCP Keepalive for faster dead connection detection
    "net.ipv4.tcp_keepalive_time" = 120; # 2 minutes
    "net.ipv4.tcp_keepalive_intvl" = 30; # 30 seconds
    "net.ipv4.tcp_keepalive_probes" = 5;

    # SYN flood protection
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_syn_retries" = 2;
    "net.ipv4.tcp_synack_retries" = 2;
    "net.ipv4.tcp_max_syn_backlog" = 4096;

    # TCP Segmentation Offload settings
    "net.ipv4.tcp_tso_win_divisor" = 3;

    # MPTCP (Multipath TCP) - if kernel supports it
    "net.mptcp.enabled" = lib.mkDefault 1;
    "net.mptcp.checksum_enabled" = lib.mkDefault 0;

    # BPF JIT for better eBPF/XDP performance
    "net.core.bpf_jit_enable" = 1;
    "net.core.bpf_jit_harden" = 0; # Disable hardening for performance
    "net.core.bpf_jit_kallsyms" = 1; # Help with debugging

    # Busy polling for lower latency (careful with CPU usage)
    "net.core.busy_poll" = 50;
    "net.core.busy_read" = 50;

    # Disable reverse path filtering for asymmetric routing
    "net.ipv4.conf.all.rp_filter" = 0;
    "net.ipv4.conf.default.rp_filter" = 0;

    # Increase route cache
    "net.ipv4.route.max_size" = 2147483647;
    "net.ipv6.route.max_size" = 2147483647;

    # TCP window scaling for high bandwidth-delay paths
    "net.ipv4.tcp_window_scaling" = 1;

    # Reduce TIME_WAIT state duration
    "net.ipv4.tcp_fin_timeout" = 15;

    # Enable TCP MTU probing for better performance
    "net.ipv4.tcp_mtu_probing" = 1;
    "net.ipv4.tcp_base_mss" = 1024;

    # Increase local port range for more concurrent connections
    "net.ipv4.ip_local_port_range" = "10000 65535";

    # Disable ICMP redirects for security
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
  };

  # Load additional kernel modules for performance
  boot.kernelModules = [
    "tcp_bbr" # BBR congestion control
    "sch_fq" # Fair Queue scheduler
    "sch_fq_codel" # Fair Queue with CoDel
    "nf_conntrack" # Connection tracking
    "8021q" # VLAN support
  ];

  # Kernel parameters for performance
  boot.kernelParams = [
    "mitigations=off" # Disable CPU vulnerability mitigations for performance (evaluate security risk!)
    "processor.max_cstate=1" # Disable deep C-states for lower latency
    "intel_idle.max_cstate=1" # Intel specific C-state control
    "skew_tick=1" # Reduce timer ticks congestion
    "nohz_full=2-3" # Tickless on CPU cores 2-3 (adjust based on CPU count)
    "rcu_nocbs=2-3" # Move RCU callbacks to other cores
    "net.ifnames=0" # Use traditional interface names (optional)
    "transparent_hugepage=always" # Transparent hugepages for better memory performance
  ];

  # CPU frequency governor for performance
  powerManagement.cpuFreqGovernor = "performance";

  # Disable CPU throttling
  services.thermald.enable = false; # Only if cooling is adequate!

  # IRQ balancing for better interrupt distribution
  services.irqbalance = {
    enable = true;
    # Ban IRQs from isolated CPU cores (if using CPU isolation)
    # bannedCpus = "2-3"; # Option not available in current NixOS version
  };

  # Real-time scheduling for network processes
  security.pam.loginLimits = [
    {
      domain = "@wheel";
      type = "soft";
      item = "rtprio";
      value = "99";
    }
    {
      domain = "@wheel";
      type = "hard";
      item = "rtprio";
      value = "99";
    }
  ];

  # Additional systemd service for runtime optimizations
  systemd.services.network-performance-tuning = {
    description = "Apply runtime network performance optimizations";
    wantedBy = ["network.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeScript "network-tuning" ''
        #!${pkgs.bash}/bin/bash
        set -e

        # Set CPU affinity for network interrupts
        for irq in $(grep -E 'enp[0-9]s[0-9]|eth[0-9]' /proc/interrupts | cut -d: -f1); do
          echo 1 > /proc/irq/$irq/smp_affinity_list 2>/dev/null || true
        done

        # Increase ring buffer sizes for all network interfaces
        for iface in $(ls /sys/class/net/ | grep -E '^(enp|eth|br-)'); do
          ${pkgs.ethtool}/bin/ethtool -G $iface rx 4096 tx 4096 2>/dev/null || true
        done

        # Set interrupt coalescing for lower latency
        for iface in $(ls /sys/class/net/ | grep -E '^(enp|eth)'); do
          ${pkgs.ethtool}/bin/ethtool -C $iface rx-usecs 10 tx-usecs 10 2>/dev/null || true
        done

        echo "Network performance tuning applied"
      '';
    };
  };

  # Enable kernel samepage merging for memory efficiency
  hardware.ksm.enable = true;
  hardware.ksm.sleep = 20; # Check every 20ms
}
