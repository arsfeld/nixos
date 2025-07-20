#!/usr/bin/env bash
# Test script for GitHub issue creation

set -euo pipefail

# Create test files
STATUS_FILE=$(mktemp)
JOURNAL_FILE=$(mktemp)
LLM_FILE=$(mktemp)

# Simulate service status output
cat > "$STATUS_FILE" << 'EOF'
● test-service.service - Test Service
     Loaded: loaded (/etc/systemd/system/test-service.service; enabled; vendor preset: enabled)
     Active: failed (Result: exit-code) since Mon 2025-01-20 10:30:00 UTC; 5s ago
    Process: 12345 ExecStart=/usr/bin/test-service (code=exited, status=1/FAILURE)
   Main PID: 12345 (code=exited, status=1/FAILURE)
        CPU: 123ms

Jan 20 10:30:00 testhost systemd[1]: Started Test Service.
Jan 20 10:30:00 testhost test-service[12345]: Error: Unable to connect to database
Jan 20 10:30:00 testhost test-service[12345]: Fatal: Service cannot continue
Jan 20 10:30:00 testhost systemd[1]: test-service.service: Main process exited, code=exited, status=1/FAILURE
Jan 20 10:30:00 testhost systemd[1]: test-service.service: Failed with result 'exit-code'.
EOF

# Simulate journal output
cat > "$JOURNAL_FILE" << 'EOF'
-- Journal begins at Mon 2025-01-20 00:00:00 UTC. --
Jan 20 10:29:55 testhost test-service[12345]: Starting test service...
Jan 20 10:29:55 testhost test-service[12345]: Attempting to connect to database at localhost:5432
Jan 20 10:29:56 testhost test-service[12345]: Connection attempt 1 failed: Connection refused
Jan 20 10:29:57 testhost test-service[12345]: Connection attempt 2 failed: Connection refused
Jan 20 10:29:58 testhost test-service[12345]: Connection attempt 3 failed: Connection refused
Jan 20 10:29:59 testhost test-service[12345]: All connection attempts failed
Jan 20 10:30:00 testhost test-service[12345]: Error: Unable to connect to database
Jan 20 10:30:00 testhost test-service[12345]: Fatal: Service cannot continue
EOF

# Simulate LLM analysis
cat > "$LLM_FILE" << 'EOF'
## Root Cause Analysis

The service failed due to a database connection issue. The service attempted to connect to PostgreSQL on localhost:5432 but all connection attempts were refused.

### Possible Causes:
1. PostgreSQL service is not running
2. PostgreSQL is not listening on port 5432
3. Firewall blocking the connection
4. PostgreSQL configuration issue

### Recommended Actions:
1. Check PostgreSQL service status: `systemctl status postgresql`
2. Verify PostgreSQL is listening: `ss -tlnp | grep 5432`
3. Check PostgreSQL logs: `journalctl -u postgresql -n 50`
4. Verify database credentials and connection settings
EOF

echo "Test files created:"
echo "  Status: $STATUS_FILE"
echo "  Journal: $JOURNAL_FILE"
echo "  LLM Analysis: $LLM_FILE"
echo
echo "To test the GitHub issue creation, run:"
echo
echo "nix develop -c create-github-issue \\"
echo "  --repo arsfeld/nixos \\"
echo "  --service test-service \\"
echo "  --hostname $(hostname) \\"
echo "  --status $STATUS_FILE \\"
echo "  --journal $JOURNAL_FILE \\"
echo "  --llm-analysis $LLM_FILE \\"
echo "  --failure-count 3"
echo
echo "Don't forget to clean up: rm -f $STATUS_FILE $JOURNAL_FILE $LLM_FILE"