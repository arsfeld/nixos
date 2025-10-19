{
  config,
  lib,
  pkgs,
  self,
  ...
}: {
  # Nix garbage collection settings to keep recent builds
  nix.gc = {
    automatic = true;
    dates = lib.mkForce "weekly";
    # Keep builds for 90 days to ensure deployment artifacts remain available
    options = lib.mkForce "--delete-older-than 90d";
    persistent = true;
  };

  # Keep GC roots for all host builds
  # This creates symlinks in /nix/var/nix/gcroots to prevent garbage collection
  system.activationScripts.preserveHostBuilds = ''
    # Create directory for host build GC roots
    mkdir -p /nix/var/nix/gcroots/hosts
    mkdir -p /nix/var/nix/gcroots/deploy-cache

    # Function to keep the last build of each host
    preserve_host_build() {
      local hostname=$1
      local profile_path="/nix/var/nix/profiles/per-user/root/nixos-$hostname"
      local gc_root="/nix/var/nix/gcroots/hosts/$hostname"

      # If the profile exists, create a GC root for it
      if [ -e "$profile_path" ]; then
        ln -sfn "$profile_path" "$gc_root"
        echo "Preserved build for host: $hostname"
      fi
    }

    # List of all hosts to preserve
    for host in storage cloud router r2s raspi3 core hpe g14 raider striker; do
      preserve_host_build "$host"
    done
  '';

  # Age secret for Attic credentials (JWT token for admin access)
  age.secrets."attic-credentials" = {
    file = "${self}/secrets/attic-credentials.age";
  };

  # Age secret for Attic server token (RSA key for JWT signing)
  age.secrets."attic-server-token" = {
    file = "${self}/secrets/attic-server-token.age";
    mode = "0400";
  };

  # Self-hosted Attic binary cache server
  services.atticd = {
    enable = true;

    # Environment file with RSA key for JWT signing
    environmentFile = config.age.secrets.attic-server-token.path;

    # Use local storage backend (no S3/MinIO needed)
    settings = {
      # Listen on localhost - will be exposed via tsnsrv
      listen = "127.0.0.1:8080";

      # Use local storage for binary cache data
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      # Use SQLite database
      database.url = "sqlite:///var/lib/atticd/server.db";

      # Enable compression
      compression = {
        type = "zstd";
      };

      # Garbage collection settings
      garbage-collection = {
        interval = "12 hours";
        default-retention-period = "3 months";
      };
    };
  };

  # Expose Attic via tsnsrv with Funnel for public access
  services.tsnsrv.services.attic = {
    toURL = "http://127.0.0.1:8080";
    funnel = true; # Enable public access via Tailscale Funnel
  };

  # Also add to media gateway for arsfeld.one access
  media.gateway.services.attic = {
    host = "storage";
    port = 8080;
    settings = {
      bypassAuth = true; # No authentication needed for cache reads
      funnel = true; # Public access
    };
  };

  # Script to push builds to Attic cache
  environment.systemPackages = with pkgs; [
    (writeScriptBin "cache-push" ''
      #!${pkgs.bash}/bin/bash
      set -e

      HOST="''${1:-$(hostname)}"

      echo "Building and caching host: $HOST"

      # Build the host configuration
      nix build ".#nixosConfigurations.$HOST.config.system.build.toplevel" --no-link --print-out-paths | while read path; do
        echo "Pushing $path to Attic cache..."
        attic push system "$path"
      done

      echo "Host $HOST has been cached successfully"
    '')

    (writeScriptBin "cache-all-hosts" ''
      #!${pkgs.bash}/bin/bash
      set -e

      HOSTS="storage cloud router r2s raspi3 core hpe g14 raider striker"

      for host in $HOSTS; do
        echo "========================================="
        echo "Caching host: $host"
        echo "========================================="
        cache-push "$host"
      done

      echo "All hosts have been cached"
    '')

    (writeScriptBin "deploy-cached" ''
      #!${pkgs.bash}/bin/bash
      # Deploy a host and automatically cache the build
      set -e

      HOST="''${1}"
      shift

      if [ -z "$HOST" ]; then
        echo "Usage: deploy-cached <hostname> [deploy-args]"
        exit 1
      fi

      echo "Building and caching $HOST..."
      cache-push "$HOST"

      echo "Deploying $HOST..."
      deploy --targets ".#$HOST" "$@"
    '')
    pkgs.attic-client
    pkgs.attic-server
  ];

  # Keep more store paths before garbage collection
  # This helps preserve commonly used dependencies
  nix.settings = {
    # Keep outputs of derivations with gc roots
    keep-outputs = true;
    # Keep derivations used to build gc roots
    keep-derivations = true;

    # Minimum free space (in bytes) before triggering GC
    min-free = lib.mkDefault (5 * 1024 * 1024 * 1024); # 5 GB
    # Maximum free space to maintain after GC
    max-free = lib.mkDefault (20 * 1024 * 1024 * 1024); # 20 GB
  };

  # Systemd service to cache all host builds periodically
  systemd.services.cache-all-hosts = {
    description = "Cache all NixOS host configurations to Attic";
    after = ["network-online.target" "atticd.service"];
    wants = ["network-online.target"];
    requires = ["atticd.service"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'cache-all-hosts'";
      User = "root";
    };
  };

  # Timer to run the cache service daily
  systemd.timers.cache-all-hosts = {
    description = "Timer for caching all NixOS host configurations";
    wantedBy = ["timers.target"];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  # Service to preserve deployment builds before GC
  systemd.services.preserve-deployment-builds = {
    description = "Preserve recent deployment builds before garbage collection";
    before = ["nix-gc.service"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "preserve-deployments" ''
        #!/bin/sh
        set -eu

        echo "Preserving recent deployment builds..."

        # Create GC roots for recent deployments (last 7 days)
        find /nix/var/log/nix/drvs -mtime -7 -type f 2>/dev/null | while read -r log; do
          drv=$(basename "$log" .drv.bz2)
          if [ -e "/nix/store/$drv.drv" ]; then
            root_name=$(echo "$drv" | sed 's/[^a-zA-Z0-9-]/_/g')
            ln -sfn "/nix/store/$drv.drv" "/nix/var/nix/gcroots/deploy-cache/$root_name" || true
          fi
        done

        # Also ensure all current host profiles are preserved
        for host in storage cloud router r2s raspi3 core hpe g14 raider striker; do
          profile="/nix/var/nix/profiles/per-user/root/nixos-$host"
          if [ -e "$profile" ]; then
            ln -sfn "$profile" "/nix/var/nix/gcroots/hosts/$host-current" || true
          fi
        done

        echo "Deployment builds preserved"
      '';
    };
  };

  # Ensure the preserve service runs before any GC
  systemd.services.nix-gc = {
    requires = ["preserve-deployment-builds.service"];
  };
}
