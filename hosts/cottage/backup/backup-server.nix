{
  config,
  pkgs,
  ...
}: {
  # Initialize Garage cluster layout and create buckets for backups
  # This runs once after Garage starts to set up the single-node cluster
  systemd.services.garage-init = {
    description = "Initialize Garage cluster and create backup buckets";
    wantedBy = ["garage.service"];
    after = ["garage.service"];
    requires = ["garage.service"];
    path = with pkgs; [garage_2 jq];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      # Wait for Garage to be ready
      echo "Waiting for Garage to be ready..."
      for i in $(seq 1 30); do
        if garage status 2>/dev/null; then
          break
        fi
        echo "Attempt $i: Garage not ready yet..."
        sleep 2
      done

      # Get node ID
      NODE_ID=$(garage status 2>/dev/null | grep -oP '[a-f0-9]{16}' | head -1 || true)

      if [ -z "$NODE_ID" ]; then
        echo "ERROR: Could not get Garage node ID"
        exit 1
      fi

      echo "Node ID: $NODE_ID"

      # Check if layout already configured
      LAYOUT_STATUS=$(garage layout show 2>/dev/null || true)
      if echo "$LAYOUT_STATUS" | grep -q "No layout changes"; then
        echo "Layout already configured, checking buckets..."
      else
        # Configure node in the cluster layout
        echo "Configuring cluster layout..."
        garage layout assign "$NODE_ID" -z dc1 -c 1G -t cottage || true

        # Apply the layout
        echo "Applying layout..."
        garage layout apply --version 1 || garage layout apply --version 2 || true
      fi

      # Create buckets if they don't exist
      echo "Creating buckets..."
      garage bucket create system-backups 2>/dev/null || echo "Bucket system-backups already exists"
      garage bucket create media-backups 2>/dev/null || echo "Bucket media-backups already exists"

      # Create access key for backups if it doesn't exist
      if ! garage key info backup-key 2>/dev/null; then
        echo "Creating backup access key..."
        garage key create backup-key

        # Grant permissions to buckets
        garage bucket allow system-backups --read --write --key backup-key
        garage bucket allow media-backups --read --write --key backup-key
      fi

      echo "Garage initialization complete!"
      garage bucket list
      garage key list
    '';
  };
}
