# Blog management commands

# Build and serve the blog locally for testing
serve PORT="8000":
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Try to get local IP address
    LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1 || echo "localhost")
    
    echo "Building and serving blog on http://0.0.0.0:{{ PORT }}"
    echo "Blog will be accessible at:"
    echo "  - http://localhost:{{ PORT }}"
    if [ "$LOCAL_IP" != "localhost" ]; then
        echo "  - http://${LOCAL_IP}:{{ PORT }}"
    fi
    
    echo "Press Ctrl+C to stop the server"
    
    # Use the local IP as the base URL so assets load correctly from remote hosts
    cd blog && nix run 'nixpkgs#zola' -- serve --interface 0.0.0.0 --port {{ PORT }} --base-url "http://${LOCAL_IP}"

# Build the blog without serving
build:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Building blog..."
    cd blog && nix run 'nixpkgs#zola' -- build
    echo "✓ Blog built successfully in blog/public/"

# Check the blog for issues
check:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Checking blog for issues..."
    cd blog && nix run 'nixpkgs#zola' -- check
    echo "✓ Blog check completed"