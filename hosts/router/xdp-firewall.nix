# XDP (eXpress Data Path) high-performance packet filtering
# Provides DDoS protection and basic firewall at line rate
{
  config,
  lib,
  pkgs,
  ...
}: let
  interfaces = config.router.interfaces;

  # Build XDP tools package
  xdp-tools =
    pkgs.xdp-tools or (pkgs.callPackage ({
      stdenv,
      lib,
      fetchFromGitHub,
      libbpf,
      llvmPackages,
      pkg-config,
      m4,
      elfutils,
      libpcap,
      zlib,
    }:
      stdenv.mkDerivation rec {
        pname = "xdp-tools";
        version = "1.4.1";

        src = fetchFromGitHub {
          owner = "xdp-project";
          repo = "xdp-tools";
          rev = "v${version}";
          sha256 = "sha256-KPwRzDDPM1QO+8kY4IIUdqBhcpQCWZmqPwYUbGx3pAo=";
        };

        nativeBuildInputs = [pkg-config m4 llvmPackages.clang];
        buildInputs = [libbpf elfutils libpcap zlib];

        makeFlags = ["PREFIX=$(out)" "PRODUCTION=1"];

        meta = with lib; {
          description = "XDP tools and utilities";
          homepage = "https://github.com/xdp-project/xdp-tools";
          license = licenses.gpl2;
          platforms = platforms.linux;
        };
      }) {});

  # XDP program for basic DDoS protection (written in restricted C for eBPF)
  xdpProgram = pkgs.writeText "xdp_ddos_protect.c" ''
    #include <linux/bpf.h>
    #include <linux/in.h>
    #include <linux/if_ether.h>
    #include <linux/ip.h>
    #include <linux/ipv6.h>
    #include <linux/tcp.h>
    #include <linux/udp.h>
    #include <bpf/bpf_helpers.h>
    #include <bpf/bpf_endian.h>

    #define MAX_MAP_ENTRIES 100000
    #define RATE_LIMIT 1000  // packets per second per IP
    #define BAN_DURATION 60   // seconds

    // Map to track packet rates per source IP
    struct {
        __uint(type, BPF_MAP_TYPE_LRU_HASH);
        __uint(max_entries, MAX_MAP_ENTRIES);
        __type(key, __u32);  // IPv4 address
        __type(value, __u64); // packet count and timestamp
    } ip_rate_map SEC(".maps");

    // Map for banned IPs
    struct {
        __uint(type, BPF_MAP_TYPE_LRU_HASH);
        __uint(max_entries, 10000);
        __type(key, __u32);  // IPv4 address
        __type(value, __u64); // ban timestamp
    } banned_ips SEC(".maps");

    // Statistics map
    struct {
        __uint(type, BPF_MAP_TYPE_ARRAY);
        __uint(max_entries, 4);
        __type(key, __u32);
        __type(value, __u64);
    } stats_map SEC(".maps");

    enum stats_index {
        STATS_TOTAL = 0,
        STATS_DROPPED = 1,
        STATS_PASSED = 2,
        STATS_BANNED = 3,
    };

    static __always_inline void update_stats(__u32 index) {
        __u32 key = index;
        __u64 *value = bpf_map_lookup_elem(&stats_map, &key);
        if (value)
            __sync_fetch_and_add(value, 1);
    }

    SEC("xdp")
    int xdp_ddos_protect(struct xdp_md *ctx) {
        void *data_end = (void *)(long)ctx->data_end;
        void *data = (void *)(long)ctx->data;

        update_stats(STATS_TOTAL);

        // Parse Ethernet header
        struct ethhdr *eth = data;
        if ((void *)(eth + 1) > data_end)
            return XDP_PASS;

        // Only process IPv4 for now
        if (eth->h_proto != bpf_htons(ETH_P_IP))
            return XDP_PASS;

        // Parse IP header
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end)
            return XDP_PASS;

        __u32 src_ip = ip->saddr;

        // Check if IP is banned
        __u64 *ban_time = bpf_map_lookup_elem(&banned_ips, &src_ip);
        if (ban_time) {
            __u64 now = bpf_ktime_get_ns() / 1000000000;  // Convert to seconds
            if (now - *ban_time < BAN_DURATION) {
                update_stats(STATS_BANNED);
                return XDP_DROP;
            } else {
                // Ban expired, remove from map
                bpf_map_delete_elem(&banned_ips, &src_ip);
            }
        }

        // Rate limiting for TCP SYN packets
        if (ip->protocol == IPPROTO_TCP) {
            struct tcphdr *tcp = (void *)ip + (ip->ihl * 4);
            if ((void *)(tcp + 1) > data_end)
                return XDP_PASS;

            // Check for SYN flag without ACK (new connection attempt)
            if (tcp->syn && !tcp->ack) {
                __u64 now = bpf_ktime_get_ns() / 1000000000;
                __u64 *rate_info = bpf_map_lookup_elem(&ip_rate_map, &src_ip);

                if (rate_info) {
                    __u64 last_seen = *rate_info >> 32;
                    __u32 count = *rate_info & 0xFFFFFFFF;

                    if (now == last_seen) {
                        count++;
                        if (count > RATE_LIMIT) {
                            // Ban this IP
                            bpf_map_update_elem(&banned_ips, &src_ip, &now, BPF_ANY);
                            update_stats(STATS_DROPPED);
                            return XDP_DROP;
                        }
                        *rate_info = (last_seen << 32) | count;
                        bpf_map_update_elem(&ip_rate_map, &src_ip, rate_info, BPF_ANY);
                    } else {
                        // New second, reset counter
                        __u64 new_info = (now << 32) | 1;
                        bpf_map_update_elem(&ip_rate_map, &src_ip, &new_info, BPF_ANY);
                    }
                } else {
                    // First packet from this IP
                    __u64 new_info = (now << 32) | 1;
                    bpf_map_update_elem(&ip_rate_map, &src_ip, &new_info, BPF_ANY);
                }
            }
        }

        // Rate limiting for UDP floods
        if (ip->protocol == IPPROTO_UDP) {
            struct udphdr *udp = (void *)ip + (ip->ihl * 4);
            if ((void *)(udp + 1) > data_end)
                return XDP_PASS;

            // Block common DDoS UDP ports
            __u16 dest_port = bpf_ntohs(udp->dest);
            if (dest_port == 19 ||   // Chargen
                dest_port == 111 ||  // Portmap
                dest_port == 123 ||  // NTP
                dest_port == 161 ||  // SNMP
                dest_port == 389 ||  // LDAP
                dest_port == 1900 || // SSDP
                dest_port == 5353 || // mDNS
                dest_port == 11211)  // Memcached
            {
                // Apply stricter rate limiting for these ports
                __u64 now = bpf_ktime_get_ns() / 1000000000;
                __u64 *rate_info = bpf_map_lookup_elem(&ip_rate_map, &src_ip);

                if (rate_info) {
                    __u64 last_seen = *rate_info >> 32;
                    __u32 count = *rate_info & 0xFFFFFFFF;

                    if (now == last_seen && count > 100) {  // Lower threshold for suspect ports
                        bpf_map_update_elem(&banned_ips, &src_ip, &now, BPF_ANY);
                        update_stats(STATS_DROPPED);
                        return XDP_DROP;
                    }
                }
            }
        }

        // Check for fragmented packets (often used in attacks)
        if (ip->frag_off & bpf_htons(IP_MF | IP_OFFSET)) {
            // Drop all fragments for now (can be refined)
            update_stats(STATS_DROPPED);
            return XDP_DROP;
        }

        // Check for invalid packet sizes
        if (bpf_ntohs(ip->tot_len) > 1500 || bpf_ntohs(ip->tot_len) < 20) {
            update_stats(STATS_DROPPED);
            return XDP_DROP;
        }

        update_stats(STATS_PASSED);
        return XDP_PASS;
    }

    char _license[] SEC("license") = "GPL";
  '';

  # Script to compile and load XDP program
  loadXdpScript = pkgs.writeScript "load-xdp" ''
    #!${pkgs.bash}/bin/bash
    set -e

    XDP_PROG="/var/lib/xdp/xdp_ddos_protect.o"
    INTERFACE="${interfaces.wan}"

    echo "Compiling XDP program..."
    mkdir -p /var/lib/xdp

    # Compile the XDP program
    ${pkgs.clang}/bin/clang \
      -O2 -g -Wall -target bpf \
      -I${pkgs.linuxHeaders}/include \
      -I${pkgs.libbpf}/include \
      -c ${xdpProgram} \
      -o $XDP_PROG

    echo "Loading XDP program on $INTERFACE..."

    # Try native mode first (best performance), fall back to generic
    if ${pkgs.iproute2}/bin/ip link set dev $INTERFACE xdpdrv obj $XDP_PROG sec xdp 2>/dev/null; then
      echo "XDP program loaded in native mode (best performance)"
    elif ${pkgs.iproute2}/bin/ip link set dev $INTERFACE xdpgeneric obj $XDP_PROG sec xdp 2>/dev/null; then
      echo "XDP program loaded in generic mode (compatibility mode)"
    else
      echo "Failed to load XDP program"
      exit 1
    fi

    echo "XDP DDoS protection is active on $INTERFACE"
  '';

  # Script to unload XDP program
  unloadXdpScript = pkgs.writeScript "unload-xdp" ''
    #!${pkgs.bash}/bin/bash
    ${pkgs.iproute2}/bin/ip link set dev ${interfaces.wan} xdp off 2>/dev/null || true
    echo "XDP program unloaded from ${interfaces.wan}"
  '';

  # Script to show XDP statistics
  statsScript = pkgs.writeScript "xdp-stats" ''
    #!${pkgs.bash}/bin/bash

    if ! ${pkgs.bpftool}/bin/bpftool map list 2>/dev/null | grep -q stats_map; then
      echo "XDP not loaded or no statistics available"
      exit 1
    fi

    MAP_ID=$(${pkgs.bpftool}/bin/bpftool map list | grep stats_map | awk '{print $1}' | tr -d ':')

    echo "XDP Firewall Statistics:"
    echo "========================"

    TOTAL=$(${pkgs.bpftool}/bin/bpftool map lookup id $MAP_ID key 0 0 0 0 2>/dev/null | grep -oP 'value: \K[0-9a-f ]+' | xxd -r -p | od -An -tu8)
    DROPPED=$(${pkgs.bpftool}/bin/bpftool map lookup id $MAP_ID key 1 0 0 0 2>/dev/null | grep -oP 'value: \K[0-9a-f ]+' | xxd -r -p | od -An -tu8)
    PASSED=$(${pkgs.bpftool}/bin/bpftool map lookup id $MAP_ID key 2 0 0 0 2>/dev/null | grep -oP 'value: \K[0-9a-f ]+' | xxd -r -p | od -An -tu8)
    BANNED=$(${pkgs.bpftool}/bin/bpftool map lookup id $MAP_ID key 3 0 0 0 2>/dev/null | grep -oP 'value: \K[0-9a-f ]+' | xxd -r -p | od -An -tu8)

    echo "Total packets:  $TOTAL"
    echo "Passed:         $PASSED"
    echo "Dropped:        $DROPPED"
    echo "Banned IPs:     $BANNED"

    if [ "$TOTAL" -gt 0 ]; then
      DROP_RATE=$(echo "scale=2; $DROPPED * 100 / $TOTAL" | bc)
      echo "Drop rate:      $DROP_RATE%"
    fi

    # Export metrics for Prometheus
    mkdir -p /var/lib/prometheus/node-exporter
    cat > /var/lib/prometheus/node-exporter/xdp.prom <<EOF
    # HELP xdp_packets_total Total packets processed by XDP
    # TYPE xdp_packets_total counter
    xdp_packets_total $TOTAL
    # HELP xdp_packets_dropped Total packets dropped by XDP
    # TYPE xdp_packets_dropped counter
    xdp_packets_dropped $DROPPED
    # HELP xdp_packets_passed Total packets passed by XDP
    # TYPE xdp_packets_passed counter
    xdp_packets_passed $PASSED
    # HELP xdp_banned_ips Total IPs banned by XDP
    # TYPE xdp_banned_ips counter
    xdp_banned_ips $BANNED
    EOF
  '';
in {
  # Enable BPF JIT compilation for better performance
  boot.kernel.sysctl = {
    "net.core.bpf_jit_enable" = 1;
    "net.core.bpf_jit_harden" = 0;
    "net.core.bpf_jit_kallsyms" = 1;
  };

  # Required kernel modules
  boot.kernelModules = ["xdp"];

  # Ensure required packages are installed
  environment.systemPackages = with pkgs; [
    xdp-tools
    bpftool
    libbpf
    clang
    llvm
    iproute2
    bc # For statistics calculations
  ];

  # SystemD service to load XDP program
  systemd.services.xdp-firewall = {
    description = "XDP DDoS Protection Firewall";
    wantedBy = ["network.target"];
    after = ["network-pre.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = loadXdpScript;
      ExecStop = unloadXdpScript;

      # Restart on failure
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  # Service to collect statistics
  systemd.services.xdp-stats = {
    description = "Collect XDP statistics";
    after = ["xdp-firewall.service"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = statsScript;
    };
  };

  # Timer to run statistics collection every minute
  systemd.timers.xdp-stats = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };

  # Add XDP management commands to system
  environment.etc."xdp/README.md".text = ''
    # XDP Firewall Management

    ## View statistics:
    xdp-stats

    ## Reload XDP program:
    systemctl restart xdp-firewall

    ## Disable XDP:
    systemctl stop xdp-firewall

    ## View banned IPs:
    bpftool map dump name banned_ips

    ## Clear banned IPs:
    bpftool map delete name banned_ips key all

    ## Monitor in real-time:
    watch -n1 xdp-stats
  '';

  # Create convenience scripts
  environment.systemPackages = [
    (pkgs.writeScriptBin "xdp-stats" statsScript)
    (pkgs.writeScriptBin "xdp-reload" ''
      #!${pkgs.bash}/bin/bash
      systemctl restart xdp-firewall
    '')
    (pkgs.writeScriptBin "xdp-monitor" ''
      #!${pkgs.bash}/bin/bash
      watch -n1 ${statsScript}
    '')
  ];
}
