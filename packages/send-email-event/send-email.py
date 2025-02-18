#! /usr/bin/env -S uv run --no-project --python 3.12 --with jinja2 --with mrml python

import subprocess
import datetime
import os
import socket
from jinja2 import Template
from mrml import to_html
import logging
import argparse
from textwrap import dedent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

EMAIL_TEMPLATE = os.environ.get(
    "EMAIL_TEMPLATE", 
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "event-notification.mjml")
)


def get_command_output(command):
    try:
        return (
            subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT)
            .decode("utf-8")
            .strip()
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Error executing command: {e.output.decode('utf-8').strip()}")
        return f"Error executing command: {e.output.decode('utf-8').strip()}"
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        return f"Unexpected error: {str(e)}"


def send_email_event(event, extra_content="", email_from=None, email_to=None):
    hostname = socket.gethostname()
    current_date = datetime.datetime.now().isoformat()
    figlet_output = get_command_output(f"figlet -f slant '{hostname}'")
    system_info = {
        "OS": get_command_output("uname -s"),
        "Kernel": get_command_output("uname -r"),
        "Uptime": get_command_output("uptime"),
        "CPU": get_command_output("lscpu | grep 'Model name' | cut -f 2 -d ':'"),
        "Memory": get_command_output(
            'free -h | awk \'/^Mem:/ {print $2 " total, " $3 " used, " $4 " free"}\''
        ),
        "Disk": get_command_output(
            'df -h / | awk \'NR==2 {print $2 " total, " $3 " used, " $4 " free"}\''
        ),
    }

    subject = f"[{hostname}] {event} {current_date}"

    with open(EMAIL_TEMPLATE, "r") as f:
        mjml_template = f.read()

    try:
        template = Template(mjml_template)
        mjml_content = template.render(
            FIGLET_OUTPUT=figlet_output,
            EVENT=event,
            HOSTNAME=hostname,
            CURRENT_DATE=current_date,
            SYSTEM_INFO=system_info,
            EXTRA_CONTENT=extra_content,
        )
    except Exception as e:
        logger.error(f"Error generating MJML content: {e}")
        mjml_content = "<mjml><mj-body><mj-section><mj-column><mj-text>Failed to generate MJML content. Please check the system logs for more information.</mj-text></mj-column></mj-section></mj-body></mjml>"

    # Convert MJML to HTML using Python
    try:
        html_content = to_html(mjml_content)
    except Exception as e:
        logger.error(
            f"Error: MJML conversion failed. Sending plain text email instead. Error: {e}"
        )
        logger.error(f"Content: {mjml_content}")
        html_content = f"""
        <html>
        <body>
            <h1>System Event Notification</h1>
            <h2>{event}</h2>
            <pre>{figlet_output}</pre>
            <p>Hostname: {hostname}</p>
            <p>Date: {current_date}</p>
            <h3>System Information:</h3>
            <pre>{system_info}</pre>
            {'<h3>Extra Content:</h3><p>' + extra_content + '</p>' if extra_content else ''}
        </body>
        </html>
        """

    # Determine email addresses by overriding with arguments if provided
    if email_from is None:
        email_from = os.environ.get("EMAIL_FROM", "admin@rosenfeld.one")
    if email_to is None:
        email_to = os.environ.get("EMAIL_TO", "alex@rosenfeld.one")

    # Construct email content
    email_content = f"""
From: {email_from}
To: {email_to}
Subject: {subject}
Content-Type: text/html; charset="utf-8"

{html_content}
        """.strip(
        "\n"
    )

    logger.info(f"Email content: {email_content}")

    # Send the email using msmtp
    try:
        subprocess.run(
            ["msmtp", "-t"],
            input=email_content,
            text=True,
            check=True,
        )
        logger.info("Email sent successfully")
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to send email: {e}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Send email event notifications")
    parser.add_argument(
        "event", type=str, nargs="?", default="Unknown Event", help="Event description"
    )
    parser.add_argument(
        "extra_content",
        type=str,
        nargs="?",
        default="",
        help="Extra content for the email",
    )
    parser.add_argument(
        "--email-from", dest="email_from", type=str, help="Sender email address"
    )
    parser.add_argument(
        "--email-to", dest="email_to", type=str, help="Recipient email address"
    )

    args = parser.parse_args()

    send_email_event(
        args.event,
        args.extra_content,
        email_from=args.email_from,
        email_to=args.email_to,
    )
