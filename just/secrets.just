# Secret management commands

# Generate a new secret with specified length
generate NAME LENGTH="64":
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Check if ragenix is available
    if ! command -v ragenix &> /dev/null; then
        echo "Error: ragenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi
    
    echo "Generating {{ LENGTH }}-character key for {{ NAME }}..."
    
    # Generate the key
    key=$(openssl rand -base64 {{ LENGTH }} | tr -d '\n=' | head -c {{ LENGTH }})
    
    # Save to temporary file
    echo "$key" > "/tmp/{{ NAME }}.txt"
    
    # Encrypt with ragenix (run from secrets directory)
    echo "Encrypting {{ NAME }}..."
    cd secrets && ragenix -e "{{ NAME }}.age" --editor "sh -c 'cat > \$1' --" < "/tmp/{{ NAME }}.txt"
    rm -f "/tmp/{{ NAME }}.txt"
    
    echo "✓ Key generated and encrypted to secrets/{{ NAME }}.age"
    echo "Don't forget to add it to secrets/secrets.nix!"

# Copy an existing secret to a new name
copy SOURCE DEST:
    #!/usr/bin/env bash
    set -euo pipefail
    
    if ! command -v ragenix &> /dev/null; then
        echo "Error: ragenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi
    
    if [ ! -f "secrets/{{ SOURCE }}" ]; then
        echo "Error: Source secret secrets/{{ SOURCE }} not found"
        exit 1
    fi
    
    echo "Copying secret from {{ SOURCE }} to {{ DEST }}..."
    
    # Create temporary file
    temp_file=$(mktemp)
    trap "rm -f $temp_file" EXIT
    
    # Decrypt source (run from secrets directory)
    cd secrets && age -d -i ~/.ssh/id_ed25519 "{{ SOURCE }}" > "$temp_file"
    
    # Re-encrypt to destination
    ragenix -e "{{ DEST }}" --editor "sh -c 'cat > \$1' --" < "$temp_file"
    
    echo "✓ Secret copied to secrets/{{ DEST }}"
    echo "Don't forget to add it to secrets/secrets.nix with appropriate publicKeys!"

# Show decrypted secret (use with caution!)
show NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    
    if ! command -v ragenix &> /dev/null; then
        echo "Error: ragenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi
    
    if [ ! -f "secrets/{{ NAME }}" ]; then
        echo "Error: Secret secrets/{{ NAME }} not found"
        exit 1
    fi
    
    echo "⚠️  WARNING: This will display the secret in plain text!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    
    echo "Decrypting {{ NAME }}..."
    echo "--- BEGIN SECRET ---"
    cd secrets && age -d -i ~/.ssh/id_ed25519 "{{ NAME }}"
    echo -e "\n--- END SECRET ---"

# List all available secrets
list:
    #!/usr/bin/env bash
    echo "Available secrets:"
    if [ -d "secrets" ]; then
        ls -la secrets/*.age 2>/dev/null | awk '{print "  " $9}' | sed 's|secrets/||g' || echo "  No secrets found"
    else
        echo "Error: secrets directory not found"
    fi