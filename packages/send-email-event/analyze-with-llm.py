import google.generativeai as genai
import os
import sys
import json
import logging
from textwrap import dedent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configure the API key
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY")
if not GOOGLE_API_KEY:
    logger.error("GOOGLE_API_KEY environment variable not set")
    sys.exit(1)

genai.configure(api_key=GOOGLE_API_KEY)

def analyze_crash_log(service_name, log_content, service_status):
    """Analyze crash logs using Google's Gemini API"""
    try:
        model = genai.GenerativeModel('gemini-2.5-flash')
        
        prompt = dedent(f"""
        You are a system administrator assistant analyzing a systemd service failure on a NixOS system.
        
        Context: This is a personal NixOS configuration repository (github.com/arsfeld/nixos) with:
        - Host configurations in /hosts/HOSTNAME/configuration.nix
        - Service definitions in /hosts/HOSTNAME/services.nix
        - Reusable modules in /modules/constellation/
        - Package definitions in /packages/
        - Services often run in Podman containers
        
        Service: {service_name}
        Status: {service_status}
        Logs: {log_content}
        
        Analyze and provide ONLY:
        1. ISSUE: What failed (1-2 sentences, no markdown)
        2. CAUSE: Most likely root cause (1 sentence)
        3. FIX: NixOS-specific resolution steps referencing actual config files (2-3 bullet points)
        
        Rules:
        - Be concise and technical
        - NO greetings, subjects, or signatures
        - NO markdown formatting (no **, `, etc.)
        - Use plain text only
        - Start directly with "ISSUE:" 
        - Maximum 150 words total
        - Reference specific config files when suggesting fixes
        """)
        
        response = model.generate_content(prompt)
        return response.text
        
    except Exception as e:
        logger.error(f"Error analyzing with LLM: {str(e)}")
        return f"LLM analysis failed: {str(e)}"

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: analyze-with-llm.py <service_name> <log_file> <status_file>")
        sys.exit(1)
    
    service_name = sys.argv[1]
    log_file = sys.argv[2]
    status_file = sys.argv[3]
    
    # Read the log content
    try:
        with open(log_file, 'r') as f:
            log_content = f.read()
    except Exception as e:
        logger.error(f"Failed to read log file: {e}")
        log_content = "Unable to read log file"
    
    # Read the status content
    try:
        with open(status_file, 'r') as f:
            service_status = f.read()
    except Exception as e:
        logger.error(f"Failed to read status file: {e}")
        service_status = "Unable to read status file"
    
    # Analyze and print result
    analysis = analyze_crash_log(service_name, log_content, service_status)
    print(analysis)