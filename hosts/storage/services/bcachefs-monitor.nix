{
  config,
  lib,
  pkgs,
  ...
}: {
  # Bcachefs I/O monitoring tool - iostat-like utility for bcachefs filesystems
  environment.systemPackages = with pkgs; [
    bc # Required for floating point calculations
    # bcachefs-tools provided by configuration.nix from pkgs-unstable
    (writeScriptBin "bcachefs-iostat" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Colors
      BOLD='\033[1m'
      BLUE='\033[0;34m'
      CYAN='\033[0;36m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      RED='\033[0;31m'
      RESET='\033[0m'

      # Configuration
      INTERVAL=''${1:-2}
      COUNT=''${2:-}

      # Function to get bcachefs UUID
      get_bcachefs_uuid() {
        local mount_point="''${1:-/mnt/storage}"

        # First try to get UUID from mount point if it exists and is mounted
        if [ -d "$mount_point" ]; then
          local dev=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null | head -1 | cut -d: -f1)
          if [ -n "$dev" ]; then
            # Get UUID from bcachefs show-super
            local uuid=$(bcachefs show-super "$dev" 2>/dev/null | grep -oP 'UUID:\s+\K[0-9a-f-]+' | head -1)
            if [ -n "$uuid" ]; then
              echo "$uuid"
              return 0
            fi
          fi
        fi

        # Fallback: auto-detect from sysfs (works even if filesystem is not mounted)
        local uuid=$(ls -1 /sys/fs/bcachefs/ 2>/dev/null | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' | head -1)
        if [ -n "$uuid" ]; then
          echo "$uuid"
          return 0
        fi

        echo "Error: No bcachefs filesystem found (checked mount at $mount_point and /sys/fs/bcachefs/)" >&2
        return 1
      }

      # Function to read block device stats
      read_block_stats() {
        local dev=$1
        if [ -f "/sys/block/$dev/stat" ]; then
          cat "/sys/block/$dev/stat"
        fi
      }

      # Function to check if bcachefs device exists
      bcachefs_device_exists() {
        local uuid=$1
        local dev_id=$2
        [ -d "/sys/fs/bcachefs/$uuid/dev-$dev_id" ]
      }

      # Parse io_done output
      # Format: label : value (3 fields separated by whitespace)
      parse_io_done() {
        local data="''${1:-}"
        local mode="''${2:-read}"  # "read" or "write"

        if [ -z "$data" ]; then
          echo "0"
          return
        fi

        echo "$data" | awk -v mode="$mode:" '
          BEGIN { total = 0 }
          $1 == mode { in_section = 1; next }
          in_section && $1 == "write:" { in_section = 0 }
          in_section && NF == 3 && $2 == ":" {
            total += $3
          }
          END { print total }
        '
      }

      # Format bytes
      format_bytes() {
        local bytes=''${1:-0}
        # Handle negative values (shouldn't happen but be safe)
        if [ "$bytes" -lt 0 ]; then
          bytes=0
        fi
        if [ "$bytes" -ge 1073741824 ]; then
          printf "%.2f GB" $(echo "$bytes / 1073741824" | bc -l)
        elif [ "$bytes" -ge 1048576 ]; then
          printf "%.2f MB" $(echo "$bytes / 1048576" | bc -l)
        elif [ "$bytes" -ge 1024 ]; then
          printf "%.2f KB" $(echo "$bytes / 1024" | bc -l)
        else
          printf "%d B" "$bytes"
        fi
      }

      # Format rate
      format_rate() {
        local bytes_per_sec=''${1:-0}
        # Handle negative values
        if [ "$bytes_per_sec" -lt 0 ]; then
          bytes_per_sec=0
        fi
        if [ "$bytes_per_sec" -ge 1048576 ]; then
          printf "%.2f MB/s" $(echo "$bytes_per_sec / 1048576" | bc -l)
        elif [ "$bytes_per_sec" -ge 1024 ]; then
          printf "%.2f KB/s" $(echo "$bytes_per_sec / 1024" | bc -l)
        else
          printf "%d B/s" "$bytes_per_sec"
        fi
      }

      # Main monitoring function
      monitor() {
        local uuid
        uuid=$(get_bcachefs_uuid) || exit 1

        # Check if filesystem is currently mounted
        local mount_status="Not mounted"
        local mount_point=$(findmnt -n -o TARGET -S "*$uuid*" 2>/dev/null | head -1)
        if [ -n "$mount_point" ]; then
          mount_status="Mounted at $mount_point"
        fi

        echo -e "''${BOLD}''${CYAN}Bcachefs I/O Statistics Monitor''${RESET}"
        echo -e "''${BLUE}UUID: $uuid''${RESET}"
        echo -e "''${BLUE}Status: $mount_status''${RESET}"
        echo -e "''${BLUE}Interval: ''${INTERVAL}s''${RESET}"
        echo ""

        # Discover bcachefs devices
        local dev_ids=()
        local dev_labels=()

        for dev_path in /sys/fs/bcachefs/$uuid/dev-*; do
          if [ -d "$dev_path" ]; then
            local dev_id=$(basename "$dev_path" | sed 's/dev-//')
            local label=$(cat "$dev_path/label" 2>/dev/null || echo "dev-$dev_id")
            dev_ids+=("$dev_id")
            dev_labels+=("$label")
          fi
        done

        if [ ''${#dev_ids[@]} -eq 0 ]; then
          echo "Error: No bcachefs devices found for UUID $uuid" >&2
          exit 1
        fi

        # Previous stats arrays
        declare -A prev_read_bytes prev_write_bytes
        local prev_time=$(date +%s)

        local iteration=0
        while true; do
          local current_time=$(date +%s)
          local elapsed=$((current_time - prev_time))

          if [ $elapsed -eq 0 ]; then
            elapsed=1
          fi

          # Print header
          if [ $((iteration % 20)) -eq 0 ]; then
            echo -e "''${BOLD}$(date '+%Y-%m-%d %H:%M:%S')''${RESET}"
            printf "''${BOLD}%-15s %12s %12s %10s %10s %12s %12s''${RESET}\n" \
              "Device" "Read" "Write" "r/s" "w/s" "rLat(μs)" "wLat(μs)"
            printf "''${BOLD}%-15s %12s %12s %10s %10s %12s %12s''${RESET}\n" \
              "---------------" "------------" "------------" "----------" "----------" "------------" "------------"
          fi

          # Collect and display stats for each device
          for i in "''${!dev_ids[@]}"; do
            local dev_id="''${dev_ids[$i]}"
            local label="''${dev_labels[$i]}"

            # Check if device exists
            if ! bcachefs_device_exists "$uuid" "$dev_id"; then
              continue
            fi

            # Read stats directly from sysfs
            local base_path="/sys/fs/bcachefs/$uuid/dev-$dev_id"
            local io_done=$(cat "$base_path/io_done" 2>/dev/null || echo "")
            local latency_read=$(cat "$base_path/io_latency_read" 2>/dev/null || echo "0")
            local latency_write=$(cat "$base_path/io_latency_write" 2>/dev/null || echo "0")

            local read_bytes=$(parse_io_done "$io_done" "read")
            local write_bytes=$(parse_io_done "$io_done" "write")

            # Ensure we have numeric values
            read_bytes=''${read_bytes:-0}
            write_bytes=''${write_bytes:-0}
            latency_read=''${latency_read:-0}
            latency_write=''${latency_write:-0}

            # Calculate rates
            local read_rate=0
            local write_rate=0

            if [ -n "''${prev_read_bytes[$dev_id]:-}" ]; then
              read_rate=$(( (read_bytes - ''${prev_read_bytes[$dev_id]}) / elapsed ))
              write_rate=$(( (write_bytes - ''${prev_write_bytes[$dev_id]}) / elapsed ))
            fi

            prev_read_bytes[$dev_id]=$read_bytes
            prev_write_bytes[$dev_id]=$write_bytes

            # Display stats
            local read_str=$(format_rate $read_rate)
            local write_str=$(format_rate $write_rate)

            # Color code based on activity
            local color=""
            if [ $read_rate -gt 10485760 ] || [ $write_rate -gt 10485760 ]; then  # > 10 MB/s
              color="''${GREEN}"
            elif [ $read_rate -gt 1048576 ] || [ $write_rate -gt 1048576 ]; then  # > 1 MB/s
              color="''${YELLOW}"
            fi

            printf "''${color}%-15s %12s %12s %10s %10s %12s %12s''${RESET}\n" \
              "$label" \
              "$(format_bytes $read_bytes)" \
              "$(format_bytes $write_bytes)" \
              "$read_str" \
              "$write_str" \
              "$latency_read" \
              "$latency_write"
          done

          echo ""

          prev_time=$current_time
          iteration=$((iteration + 1))

          # Check if we should exit
          if [ -n "$COUNT" ] && [ $iteration -ge "$COUNT" ]; then
            break
          fi

          sleep "$INTERVAL"
        done
      }

      # Handle Ctrl+C gracefully
      trap 'echo -e "\n''${YELLOW}Monitoring stopped''${RESET}"; exit 0' INT TERM

      # Check if bcachefs tools are available
      if ! command -v bcachefs &> /dev/null; then
        echo "Error: bcachefs command not found. Is bcachefs-tools installed?" >&2
        exit 1
      fi

      # Check if bc is available
      if ! command -v bc &> /dev/null; then
        echo "Error: bc command not found. Is bc installed?" >&2
        exit 1
      fi

      # Show usage
      if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
        echo "Usage: bcachefs-iostat [interval] [count]"
        echo ""
        echo "Display bcachefs I/O statistics similar to iostat"
        echo ""
        echo "Arguments:"
        echo "  interval    Seconds between updates (default: 2)"
        echo "  count       Number of reports to display (default: infinite)"
        echo ""
        echo "Examples:"
        echo "  bcachefs-iostat           # Update every 2 seconds"
        echo "  bcachefs-iostat 5         # Update every 5 seconds"
        echo "  bcachefs-iostat 1 10      # Update every 1 second, 10 times"
        exit 0
      fi

      monitor
    '')
  ];
}
