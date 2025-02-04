from playwright.sync_api import sync_playwright
import os
import subprocess
import sys
import logging
from datetime import datetime
from mrml import to_html
import argparse
import requests

# Configure logging
log_dir = os.path.expanduser("~/.local/share/check-stock")
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, "check-stock.log")

template_path = os.environ.get('EMAIL_TEMPLATE_PATH', 'email-template.mjml')

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(log_file)
    ]
)
logger = logging.getLogger(__name__)

def send_notification_ntfy(url, title, server="ntfy.sh"):
    servers = {
        "ntfy.sh": "https://ntfy.sh/arsfeld-product-available",
        "personal": "https://ntfy.arsfeld.one/product-available"
    }
    
    try:
        # Determine which servers to notify
        targets = []
        if server == "both":
            targets = list(servers.values())
        else:
            targets = [servers[server]]
        
        # Send notifications
        for target in targets:
            response = requests.post(
                target,
                data=f"{title} is available!".encode(encoding='utf-8'),
                headers={"Click": url, "Priority": "high", "Email": "alex@rosenfeld.one"}
            )
            server_name = target.split("//")[1].split("/")[0]  # Extract domain from URL
            logger.info(f"{server_name} response status: {response.status_code}")
            if response.status_code != 200:
                logger.error(f"{server_name} error response: {response.text}")

    except requests.exceptions.RequestException as e:
        logger.error(f"Failed to send ntfy notification: {e}", exc_info=True)

def send_notification_email(url, title):
    try:
        # Read and render MJML template
        with open(template_path, 'r') as f:
            mjml_content = f.read()

        # Replace placeholders
        mjml_content = mjml_content.replace('{{url}}', url)
        mjml_content = mjml_content.replace('{{title}}', title)

        # Render MJML to HTML
        html_output = to_html(mjml_content)

        email_content = f"""Subject: {title} is Available!
To: alex@rosenfeld.one
Content-Type: text/html; charset=UTF-8
MIME-Version: 1.0

{html_output}
"""
        # Send email using msmtp
        process = subprocess.Popen(
            ['msmtp', 'alex@rosenfeld.one'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        stdout, stderr = process.communicate(input=email_content.encode())

        if process.returncode == 0:
            logger.info("Notification email sent successfully")
        else:
            logger.error(f"Failed to send email: {stderr.decode()}")
    except Exception as e:
        logger.error(f"Failed to send email: {e}", exc_info=True)

def check_add_to_bag_button(url, ntfy_server):
    logger.info(f"Starting check for URL: {url}")
    with sync_playwright() as p:
        logger.debug("Initializing Playwright")
        browser = p.firefox.launch(
            headless=True,
        )
        page = browser.new_page()

        try:
            logger.info("Navigating to page")
            page.goto(url)

            # Get the page title
            title = page.title()
            logger.debug(f"Page title: {title}")

            logger.debug("Looking for 'Add to bag' button")
            button = page.locator('[data-test-id="add-to-bag-button"]')

            if button.is_visible():
                logger.info("'Add to bag' button is visible")
                send_notification_ntfy(url, title, ntfy_server)
                send_notification_email(url, title)
                return True
            else:
                logger.info("'Add to bag' button is present but not visible")
                return False

        except Exception as e:
            logger.error(f"An error occurred: {e}", exc_info=True)
            return False
        finally:
            logger.debug("Closing browser")
            browser.close()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        logger.error("No URLs provided. Usage: check-stock.py URL1 [URL2 ...]")
        sys.exit(1)

    parser = argparse.ArgumentParser(description='Check stock availability.')
    parser.add_argument('urls', nargs='+', help='URLs to check')
    parser.add_argument('--ntfy-server', choices=['ntfy.sh', 'personal', 'both'], 
                       default='ntfy.sh', help='Choose notification server (default: ntfy.sh)')
    
    args = parser.parse_args()
    logger.info("Starting stock check script")

    for url in args.urls:
        logger.info(f"Checking URL: {url}")
        check_add_to_bag_button(url, args.ntfy_server) 