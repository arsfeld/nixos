#!/usr/bin/env python3
"""Test script for LLM crash log analysis"""

import tempfile
import subprocess
import os

# Sample crash log data
SAMPLE_SERVICE_STATUS = """● nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/etc/systemd/system/nginx.service; enabled; vendor preset: enabled)
     Active: failed (Result: exit-code) since Mon 2025-01-19 10:23:45 UTC; 5min ago
       Docs: man:nginx(8)
    Process: 12345 ExecStartPre=/usr/sbin/nginx -t (code=exited, status=1/FAILURE)
    Process: 12346 ExecStartPre=/usr/sbin/nginx -g daemon on; master_process on; (code=exited, status=1/FAILURE)
   Main PID: 12347 (code=exited, status=1/FAILURE)
        CPU: 15ms

Jan 19 10:23:45 server nginx[12345]: nginx: [emerg] duplicate location "/api" in /etc/nginx/sites-enabled/myapp.conf:42
Jan 19 10:23:45 server nginx[12345]: nginx: configuration file /etc/nginx/nginx.conf test failed
Jan 19 10:23:45 server systemd[1]: nginx.service: Control process exited, code=exited, status=1/FAILURE
Jan 19 10:23:45 server systemd[1]: nginx.service: Failed with result 'exit-code'.
Jan 19 10:23:45 server systemd[1]: Failed to start A high performance web server and a reverse proxy server."""

SAMPLE_LOGS = """Jan 19 10:23:45 server systemd[1]: Starting A high performance web server and a reverse proxy server...
Jan 19 10:23:45 server nginx[12345]: nginx: [emerg] duplicate location "/api" in /etc/nginx/sites-enabled/myapp.conf:42
Jan 19 10:23:45 server nginx[12345]: nginx: configuration file /etc/nginx/nginx.conf test failed
Jan 19 10:23:45 server systemd[1]: nginx.service: Control process exited, code=exited, status=1/FAILURE
Jan 19 10:23:45 server systemd[1]: nginx.service: Failed with result 'exit-code'.
Jan 19 10:23:45 server systemd[1]: Failed to start A high performance web server and a reverse proxy server.
Jan 19 10:23:44 server nginx[12344]: 2025/01/19 10:23:44 [notice] 12344#12344: signal process started
Jan 19 10:23:44 server systemd[1]: Reloading A high performance web server and a reverse proxy server...
Jan 19 10:23:43 server nginx[12343]: 192.168.1.100 - - [19/Jan/2025:10:23:43 +0000] "GET /health HTTP/1.1" 200 2 "-" "kube-probe/1.24"
Jan 19 10:23:42 server nginx[12342]: 192.168.1.101 - - [19/Jan/2025:10:23:42 +0000] "POST /api/v1/users HTTP/1.1" 201 145 "-" "Mozilla/5.0"
"""

def test_llm_analysis():
    """Test the LLM analysis functionality"""
    
    # Check if API key is set
    api_key = os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        print("Error: GOOGLE_API_KEY environment variable not set")
        print("Please set it with: export GOOGLE_API_KEY='your-api-key-here'")
        return
    
    # Create temporary files
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as log_file:
        log_file.write(SAMPLE_LOGS)
        log_file_path = log_file.name
    
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as status_file:
        status_file.write(SAMPLE_SERVICE_STATUS)
        status_file_path = status_file.name
    
    try:
        # Run the analysis script
        print("Testing LLM analysis with sample nginx crash log...\n")
        
        result = subprocess.run(
            ["python3", "packages/send-email-event/analyze-with-llm.py", 
             "nginx.service", log_file_path, status_file_path],
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            print("✓ Analysis successful!\n")
            print("LLM Analysis Output:")
            print("-" * 80)
            print(result.stdout)
            print("-" * 80)
        else:
            print("✗ Analysis failed!")
            print("Error:", result.stderr)
    
    finally:
        # Clean up temporary files
        os.unlink(log_file_path)
        os.unlink(status_file_path)

if __name__ == "__main__":
    test_llm_analysis()