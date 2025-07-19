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
        You are a system administrator assistant analyzing a systemd service failure.
        
        Service Name: {service_name}
        
        Service Status:
        {service_status}
        
        Recent Logs (last 50 lines):
        {log_content}
        
        Please provide a concise analysis with:
        1. A brief summary of what went wrong (2-3 sentences)
        2. The likely root cause
        3. 2-3 specific steps to resolve the issue
        
        Format your response in a clear, structured way suitable for an email notification.
        Keep the total response under 300 words.
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