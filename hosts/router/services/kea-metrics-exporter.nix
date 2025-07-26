{
  config,
  lib,
  pkgs,
  ...
}: {
  # Kea DHCP metrics exporter service
  systemd.services.kea-metrics-exporter = {
    description = "Export Kea DHCP metrics for Prometheus";
    after = ["kea-dhcp4-server.service" "prometheus-node-exporter.service"];
    wants = ["kea-dhcp4-server.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = let
        script = pkgs.writeScript "export-kea-metrics" ''
          #!${pkgs.bash}/bin/bash

          # Set PATH to include necessary utilities
          export PATH="${pkgs.coreutils}/bin:${pkgs.jq}/bin:${pkgs.curl}/bin:${pkgs.bc}/bin:${pkgs.gnugrep}/bin:${pkgs.gawk}/bin:$PATH"

          mkdir -p /var/lib/prometheus-node-exporter-text-files

          # Kea control socket path
          CONTROL_SOCKET="/var/lib/kea/kea-dhcp4.sock"

          # Function to send command to Kea control socket
          send_kea_command() {
            local cmd="$1"
            if [ -S "$CONTROL_SOCKET" ]; then
              echo "$cmd" | ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$CONTROL_SOCKET" 2>/dev/null || echo '{"result": 1}'
            else
              echo '{"result": 1}'
            fi
          }

          # Function to get Kea statistics
          get_kea_stats() {
            local stats_json=$(send_kea_command '{"command": "statistic-get-all"}')

            if echo "$stats_json" | jq -e '.result == 0' >/dev/null 2>&1; then
              echo "$stats_json"
            else
              echo '{"result": 1, "arguments": {}}'
            fi
          }

          # Function to get lease statistics
          get_lease_stats() {
            local subnet_stats=$(send_kea_command '{"command": "stat-lease4-get"}')

            if echo "$subnet_stats" | jq -e '.result == 0' >/dev/null 2>&1; then
              echo "$subnet_stats"
            else
              # Fallback: count leases from lease file if control socket fails
              local lease_count=0
              if [ -f "/var/lib/kea/kea-leases4.csv" ]; then
                # Count non-comment lines in lease file
                lease_count=$(grep -v '^#' /var/lib/kea/kea-leases4.csv 2>/dev/null | wc -l || echo "0")
              fi
              echo "{\"result\": 0, \"arguments\": {\"total-addresses\": $lease_count}}"
            fi
          }

          # Main loop
          while true; do
            {
              echo "# HELP kea_dhcp4_status Kea DHCP4 service status (1=active, 0=inactive)"
              echo "# TYPE kea_dhcp4_status gauge"
              if systemctl is-active kea-dhcp4-server >/dev/null 2>&1; then
                echo "kea_dhcp4_status 1"
              else
                echo "kea_dhcp4_status 0"
              fi

              # Get Kea statistics
              stats_json=$(get_kea_stats)

              if echo "$stats_json" | jq -e '.result == 0' >/dev/null 2>&1; then
                # Extract packet statistics
                for stat_type in "pkt4-received" "pkt4-discover-received" "pkt4-offer-sent" "pkt4-request-received" "pkt4-ack-sent" "pkt4-nak-sent" "pkt4-release-received" "pkt4-decline-received" "pkt4-inform-received"; do
                  stat_value=$(echo "$stats_json" | jq -r ".arguments.\"$stat_type\"[0][0] // 0")
                  stat_name=$(echo "$stat_type" | tr '-' '_')

                  echo "# HELP kea_dhcp4_$stat_name Total number of $stat_type packets"
                  echo "# TYPE kea_dhcp4_$stat_name counter"
                  echo "kea_dhcp4_$stat_name $stat_value"
                done

                # Extract allocation statistics
                for stat_type in "v4-allocation-fail" "v4-allocation-fail-shared-network" "v4-allocation-fail-subnet" "v4-allocation-fail-no-pools" "v4-allocation-fail-classes"; do
                  stat_value=$(echo "$stats_json" | jq -r ".arguments.\"$stat_type\"[0][0] // 0")
                  stat_name=$(echo "$stat_type" | tr '-' '_')

                  echo "# HELP kea_dhcp4_$stat_name Total number of $stat_type events"
                  echo "# TYPE kea_dhcp4_$stat_name counter"
                  echo "kea_dhcp4_$stat_name $stat_value"
                done

                # Extract lease statistics per subnet
                for subnet_id in 1; do  # We only have subnet ID 1 configured
                  for lease_type in "total-addresses" "assigned-addresses" "declined-addresses" "declined-reclaimed-addresses" "reclaimed-leases"; do
                    stat_key="subnet[$subnet_id].$lease_type"
                    stat_value=$(echo "$stats_json" | jq -r ".arguments.\"$stat_key\"[0][0] // 0")
                    stat_name=$(echo "$lease_type" | tr '-' '_')

                    echo "# HELP kea_dhcp4_subnet_$stat_name Number of $lease_type in subnet"
                    echo "# TYPE kea_dhcp4_subnet_$stat_name gauge"
                    echo "kea_dhcp4_subnet_$stat_name{subnet_id=\"$subnet_id\"} $stat_value"
                  done
                done
              fi

              # Get lease statistics
              lease_stats=$(get_lease_stats)
              # Active leases from lease file (counting unique IP addresses)
              if [ -f "/var/lib/kea/kea-leases4.csv" ]; then
                # Get current timestamp
                current_time=$(date +%s)
                
                # Count unique IP addresses with non-expired leases (state=0 means active)
                active_leases=$(grep -v '^#' /var/lib/kea/kea-leases4.csv 2>/dev/null | \
                  awk -F, -v now="$current_time" '$10 == 0 && $5 > now {print $1}' | \
                  sort -u | wc -l || echo "0")
                
                echo "# HELP kea_dhcp4_active_leases Number of unique active DHCP leases"
                echo "# TYPE kea_dhcp4_active_leases gauge"
                echo "kea_dhcp4_active_leases $active_leases"
                
                # Export individual lease information
                echo "# HELP kea_dhcp4_lease_info DHCP lease information (1=active, 0=expired)"
                echo "# TYPE kea_dhcp4_lease_info gauge"
                
                # Get hostname mapping from DHCP hosts file
                declare -A hostnames
                if [ -f "/var/lib/kea/dhcp-hosts" ]; then
                  while IFS=' ' read -r ip hostname rest; do
                    if [[ ! "$ip" =~ ^# ]] && [ -n "$ip" ] && [ -n "$hostname" ]; then
                      # Remove .lan suffix if present
                      hostname=''${hostname%.lan}
                      hostnames["$ip"]="$hostname"
                    fi
                  done < /var/lib/kea/dhcp-hosts
                fi
                
                # Process each lease in the CSV file
                # CSV format: IP,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state
                grep -v '^#' /var/lib/kea/kea-leases4.csv 2>/dev/null | while IFS=',' read -r ip hwaddr client_id valid_lifetime expire subnet_id fqdn_fwd fqdn_rev hostname state rest; do
                  # Skip if state is not 0 (active)
                  if [ "$state" != "0" ]; then
                    continue
                  fi
                  
                  # Check if lease is expired
                  if [ "$expire" -le "$current_time" ]; then
                    continue
                  fi
                  
                  # Calculate remaining time
                  remaining=$((expire - current_time))
                  
                  # Get hostname from various sources
                  display_name="unknown"
                  if [ -n "''${hostnames[$ip]}" ]; then
                    display_name="''${hostnames[$ip]}"
                  elif [ -n "$hostname" ] && [ "$hostname" != "" ]; then
                    display_name="$hostname"
                  fi
                  
                  # Clean up MAC address format
                  mac_clean=$(echo "$hwaddr" | tr -d ':' | tr '[:upper:]' '[:lower:]')
                  
                  # Output metric with labels
                  echo "kea_dhcp4_lease_info{ip=\"$ip\",mac=\"$hwaddr\",hostname=\"$display_name\",expire_ts=\"$expire\",remaining_s=\"$remaining\"} 1"
                done
              fi

              # Pool utilization calculation
              # Pool range from Nix configuration
              pool_start=${toString config.router.network.dhcpPool.start}
              pool_end=${toString config.router.network.dhcpPool.end}
              total_pool_size=$((pool_end - pool_start + 1))

              if [ -f "/var/lib/kea/kea-leases4.csv" ]; then
                # Count unique IP addresses in the pool range with active leases
                pool_leases=$(grep -v '^#' /var/lib/kea/kea-leases4.csv 2>/dev/null | \
                  awk -F, -v prefix="${config.router.network.prefix}" -v start="$pool_start" -v end="$pool_end" -v now="$current_time" \
                  '$10 == 0 && $5 > now && $1 ~ "^"prefix"\\." {
                    split($1, parts, ".")
                    last_octet = parts[4]
                    if (last_octet >= start && last_octet <= end) {
                      ips[$1] = 1
                    }
                  } END {print length(ips)+0}' || echo "0")
                pool_utilization=$(echo "scale=2; $pool_leases * 100 / $total_pool_size" | bc -l 2>/dev/null || echo "0")

                echo "# HELP kea_dhcp4_pool_utilization_percent DHCP pool utilization percentage"
                echo "# TYPE kea_dhcp4_pool_utilization_percent gauge"
                echo "kea_dhcp4_pool_utilization_percent $pool_utilization"

                echo "# HELP kea_dhcp4_pool_size Total size of DHCP pool"
                echo "# TYPE kea_dhcp4_pool_size gauge"
                echo "kea_dhcp4_pool_size $total_pool_size"

                echo "# HELP kea_dhcp4_pool_used Number of addresses used from DHCP pool"
                echo "# TYPE kea_dhcp4_pool_used gauge"
                echo "kea_dhcp4_pool_used $pool_leases"
              fi

            } > /var/lib/prometheus-node-exporter-text-files/kea.prom.tmp

            # Atomic move to avoid partial reads
            mv /var/lib/prometheus-node-exporter-text-files/kea.prom.tmp \
               /var/lib/prometheus-node-exporter-text-files/kea.prom

            sleep 30
          done
        '';
      in "${script}";
      Restart = "always";
      RestartSec = "30s";
      # Run as root to access prometheus text files directory
      # The script will still be able to connect to Kea socket
    };
  };

  # Ensure the kea socket is accessible
  systemd.services.kea-dhcp4-server = {
    serviceConfig = {
      ExecStartPost = let
        script = pkgs.writeScript "chmod-kea-socket" ''
          #!${pkgs.bash}/bin/bash
          # Wait a moment for the socket to be created
          sleep 1
          if [ -S /var/lib/kea/kea-dhcp4.sock ]; then
            ${pkgs.coreutils}/bin/chmod 666 /var/lib/kea/kea-dhcp4.sock
          fi
        '';
      in "+${script}";
    };
  };
}
