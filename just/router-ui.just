# Router UI development commands

# Start Router UI development server
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Starting Router UI development server..."
    cd packages/router_ui
    
    # Enter nix shell and run Go server
    nix shell "nixpkgs#go" "nixpkgs#nodejs" "nixpkgs#nodePackages.npm" "nixpkgs#tailwindcss" -c bash -c '
        # Download Go dependencies and create go.sum
        echo "Downloading Go dependencies..."
        go mod tidy
        
        # Install web dependencies if needed
        if [ ! -d "web/node_modules" ]; then
            echo "Installing npm dependencies..."
            cd web && npm install --legacy-peer-deps && cd ..
        fi
        
        # Build web assets
        echo "Building web assets..."
        cd web
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --minify
        cp ./src/js/app.js ./static/js/app.js
        cp node_modules/alpinejs/dist/cdn.min.js ./static/js/alpine.min.js
        cd ..
        
        # Create data directory for development and clean up any locks
        mkdir -p /tmp/router-ui-dev
        rm -f /tmp/router-ui-dev/db/LOCK
        
        # Start Go server
        echo "Starting Router UI server on http://localhost:4000"
        go run main.go -db /tmp/router-ui-dev/db -port 4000
    '

# Setup Router UI development environment
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Setting up Router UI development environment..."
    cd packages/router_ui
    
    nix shell "nixpkgs#go" "nixpkgs#nodejs" "nixpkgs#nodePackages.npm" "nixpkgs#tailwindcss" -c bash -c '
        # Download Go dependencies and create go.sum
        echo "Downloading Go dependencies..."
        go mod tidy
        
        # Install npm dependencies
        echo "Installing npm dependencies..."
        cd web && npm install --legacy-peer-deps && cd ..
        
        # Build web assets
        echo "Building web assets..."
        cd web
        mkdir -p static/css static/js
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --minify
        cp ./src/js/app.js ./static/js/app.js
        cp node_modules/alpinejs/dist/cdn.min.js ./static/js/alpine.min.js
        cd ..
        
        echo "✓ Router UI setup complete!"
        echo "Run 'just router-ui-dev' to start the development server"
    '

# Run Router UI tests
test:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Running Router UI tests..."
    cd packages/router_ui
    
    nix shell "nixpkgs#go" -c go test ./...

# Build Router UI release
build:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Building Router UI release..."
    cd packages/router_ui
    
    nix build ./. -L
    echo "✓ Router UI built successfully!"
    
    # Also push to cache if available
    if command -v attic &> /dev/null; then
        echo "Pushing to cache..."
        attic push system result
    fi

# Start Router UI with hot-reload
watch:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Starting Router UI with hot-reload..."
    cd packages/router_ui
    
    nix shell "nixpkgs#go" "nixpkgs#nodejs" "nixpkgs#nodePackages.npm" "nixpkgs#tailwindcss" "nixpkgs#entr" -c bash -c '
        # Download Go dependencies and create go.sum
        echo "Downloading Go dependencies..."
        go mod tidy
        
        # Install dependencies if needed
        if [ ! -d "web/node_modules" ]; then
            echo "Installing npm dependencies..."
            cd web && npm install --legacy-peer-deps && cd ..
        fi
        
        # Create data directory for development and clean up any locks
        mkdir -p /tmp/router-ui-dev
        rm -f /tmp/router-ui-dev/db/LOCK
        
        # Create directories
        mkdir -p web/static/css web/static/js
        
        # Copy JS files
        cp web/src/js/app.js web/static/js/app.js
        cp web/node_modules/alpinejs/dist/cdn.min.js web/static/js/alpine.min.js
        
        # Build CSS initially
        echo "Building CSS..."
        cd web
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --minify
        cd ..
        
        # Run tailwindcss watch in background
        echo "Starting CSS watcher..."
        cd web
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --watch &
        CSS_PID=$!
        cd ..
        
        # Function to cleanup background process
        cleanup() {
            echo "Stopping CSS watcher..."
            kill $CSS_PID 2>/dev/null || true
        }
        trap cleanup EXIT
        
        # Watch Go files and restart on changes
        echo "Starting Go server with auto-reload..."
        find . -name "*.go" -o -name "*.html" | entr -r go run main.go -db /tmp/router-ui-dev/db -port 4000
    '

# Deploy Router UI to target
deploy TARGET="router":
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Deploying Router UI to {{ TARGET }}..."
    
    # Build the package first
    echo "Building Router UI..."
    cd packages/router_ui && nix build ./. -L
    
    # Deploy the configuration
    echo "Deploying to {{ TARGET }}..."
    just deploy {{ TARGET }}
    
    echo "✓ Router UI deployed to {{ TARGET }}"
    echo "Access it at: http://{{ TARGET }}.bat-boa.ts.net:4000 or via Caddy proxy"