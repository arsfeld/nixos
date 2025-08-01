# Supabase management commands

# Create a new Supabase instance
create INSTANCE:
    modules/supabase/scripts/create-instance {{INSTANCE}}

# Delete a Supabase instance
delete INSTANCE:
    modules/supabase/scripts/delete-instance {{INSTANCE}}

# Update a secret for a Supabase instance
update-secret INSTANCE SECRET:
    modules/supabase/scripts/update-secret {{INSTANCE}} {{SECRET}}

# Show status of all Supabase instances
status:
    #!/usr/bin/env bash
    echo "=== Supabase Instances ==="
    for instance in /var/lib/supabase-*; do
        if [ -d "$instance" ]; then
            name=$(basename "$instance" | sed 's/supabase-//')
            echo "Instance: $name"
            if systemctl is-active --quiet "supabase-$name"; then
                echo "  Status: Running"
                echo "  Port: $(grep -o '${toString port}' "$instance/docker-compose.yml" 2>/dev/null || echo "Unknown")"
            else
                echo "  Status: Stopped"
            fi
            echo
        fi
    done

# Show information about Supabase instances
info:
    modules/supabase/scripts/info