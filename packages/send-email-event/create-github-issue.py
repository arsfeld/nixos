#!/usr/bin/env python3
"""Create GitHub issues for systemd service failures with duplicate detection."""

import argparse
import json
import os
import subprocess
import sys
import hashlib
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Tuple


def run_command(cmd: List[str]) -> Tuple[int, str, str]:
    """Run a command and return exit code, stdout, stderr."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def get_issue_hash(service_name: str, hostname: str) -> str:
    """Generate a hash for deduplication based on service and host."""
    content = f"{service_name}@{hostname}"
    return hashlib.md5(content.encode()).hexdigest()[:8]


def search_existing_issues(repo: str, service_name: str, hostname: str) -> Optional[Dict]:
    """Search for existing open issues for this service."""
    search_query = f'is:issue is:open repo:{repo} "[{hostname}] {service_name} failed" in:title'
    
    cmd = ["gh", "issue", "list", "--repo", repo, "--search", search_query, "--json", "number,title,state,createdAt"]
    exit_code, stdout, stderr = run_command(cmd)
    
    if exit_code != 0:
        print(f"Error searching issues: {stderr}", file=sys.stderr)
        return None
    
    try:
        issues = json.loads(stdout) if stdout else []
        # Find the most recent matching issue
        for issue in issues:
            if f"[{hostname}] {service_name} failed" in issue['title']:
                return issue
    except json.JSONDecodeError:
        print(f"Error parsing GitHub response: {stdout}", file=sys.stderr)
    
    return None


def create_issue_body(service_name: str, hostname: str, status_output: str, 
                     journal_output: str, llm_analysis: Optional[str] = None,
                     failure_count: int = 1) -> str:
    """Create the issue body in Markdown format."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    body = f"""## Service Failure Report

**Service:** `{service_name}`  
**Host:** `{hostname}`  
**Time:** {timestamp}  
**Failure Count:** {failure_count}

"""
    
    if llm_analysis:
        body += f"""### AI Analysis

{llm_analysis}

"""
    
    body += f"""### Service Status

```
{status_output}
```

### Recent Logs

<details>
<summary>Click to expand journal logs</summary>

```
{journal_output}
```

</details>

---
*This issue was automatically created by the systemd failure notification system.*
"""
    
    return body


def update_existing_issue(repo: str, issue_number: int, service_name: str,
                         hostname: str, status_output: str, journal_output: str,
                         llm_analysis: Optional[str] = None, failure_count: int = 1) -> bool:
    """Update an existing issue with a new failure comment including full details."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    comment = f"""## 🔄 Service Failed Again

**Service:** `{service_name}`
**Host:** `{hostname}`
**Time:** {timestamp}
**Total Failures:** {failure_count}

"""

    if llm_analysis:
        comment += f"""### 🤖 AI Analysis

{llm_analysis}

"""

    comment += f"""### 📊 Current Service Status

```
{status_output}
```

### 📝 Recent Logs

<details>
<summary>Click to expand last 50 log lines</summary>

```
{journal_output}
```

</details>

---

**Quick Actions:**
- Check live status: `ssh {hostname} systemctl status {service_name}`
- View full logs: `ssh {hostname} journalctl -u {service_name} -n 100 --no-pager`
- Restart service: `ssh {hostname} systemctl restart {service_name}`
"""

    cmd = ["gh", "issue", "comment", str(issue_number), "--repo", repo, "--body", comment]
    exit_code, stdout, stderr = run_command(cmd)

    if exit_code != 0:
        print(f"Error updating issue: {stderr}", file=sys.stderr)
        return False

    return True


def create_new_issue(repo: str, service_name: str, hostname: str, 
                    status_output: str, journal_output: str,
                    llm_analysis: Optional[str] = None,
                    failure_count: int = 1) -> bool:
    """Create a new GitHub issue."""
    issue_hash = get_issue_hash(service_name, hostname)
    title = f"[{hostname}] {service_name} failed - {issue_hash}"
    
    body = create_issue_body(service_name, hostname, status_output, 
                           journal_output, llm_analysis, failure_count)
    
    # Create labels based on service type and hostname
    labels = ["systemd-failure", f"host:{hostname}"]
    
    # Add service-specific labels
    if "backup" in service_name.lower():
        labels.append("backup")
    elif "docker" in service_name.lower() or "podman" in service_name.lower():
        labels.append("container")
    elif "nginx" in service_name.lower() or "caddy" in service_name.lower():
        labels.append("web-server")
    
    # Try to create issue with labels first
    cmd = [
        "gh", "issue", "create",
        "--repo", repo,
        "--title", title,
        "--body", body,
        "--label", ",".join(labels)
    ]

    exit_code, stdout, stderr = run_command(cmd)

    # If labels failed, try without labels
    if exit_code != 0 and "not found" in stderr.lower():
        print(f"Warning: Some labels not found, creating issue without labels", file=sys.stderr)
        cmd = [
            "gh", "issue", "create",
            "--repo", repo,
            "--title", title,
            "--body", body
        ]
        exit_code, stdout, stderr = run_command(cmd)

    if exit_code != 0:
        print(f"Error creating issue: {stderr}", file=sys.stderr)
        return False

    print(f"Created issue: {stdout}")
    return True


def main():
    parser = argparse.ArgumentParser(description="Create GitHub issues for systemd failures")
    parser.add_argument("--repo", required=True, help="GitHub repository (owner/repo)")
    parser.add_argument("--service", required=True, help="Service name that failed")
    parser.add_argument("--hostname", required=True, help="Hostname where service failed")
    parser.add_argument("--status", required=True, help="Path to service status output file")
    parser.add_argument("--journal", required=True, help="Path to journal output file")
    parser.add_argument("--llm-analysis", help="Path to LLM analysis file (optional)")
    parser.add_argument("--failure-count", type=int, default=1, help="Number of failures")
    parser.add_argument("--update-interval", type=int, default=24, 
                       help="Hours before creating new issue instead of updating (default: 24)")
    
    args = parser.parse_args()
    
    # Read input files
    try:
        with open(args.status, 'r') as f:
            status_output = f.read()
        
        with open(args.journal, 'r') as f:
            journal_output = f.read()
        
        llm_analysis = None
        if args.llm_analysis and os.path.exists(args.llm_analysis):
            with open(args.llm_analysis, 'r') as f:
                llm_analysis = f.read()
    
    except Exception as e:
        print(f"Error reading input files: {e}", file=sys.stderr)
        return 1
    
    # Check for existing issues
    existing_issue = search_existing_issues(args.repo, args.service, args.hostname)
    
    if existing_issue:
        # Check if the issue is recent enough to just update
        created_at = datetime.fromisoformat(existing_issue['createdAt'].replace('Z', '+00:00'))
        age_hours = (datetime.now(created_at.tzinfo) - created_at).total_seconds() / 3600
        
        if age_hours < args.update_interval:
            # Update existing issue with a comment
            print(f"Updating existing issue #{existing_issue['number']}")
            if update_existing_issue(args.repo, existing_issue['number'],
                                   args.service, args.hostname,
                                   status_output, journal_output,
                                   llm_analysis, args.failure_count):
                return 0
            else:
                return 1
    
    # Create new issue
    print(f"Creating new issue for {args.service} on {args.hostname}")
    if create_new_issue(args.repo, args.service, args.hostname, 
                       status_output, journal_output, llm_analysis, args.failure_count):
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())