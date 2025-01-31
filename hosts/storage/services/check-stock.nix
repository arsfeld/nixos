{
  config,
  lib,
  pkgs,
  ...
}: let
  pythonEnv = pkgs.python3.withPackages (ps:
    with ps; [
      playwright
      mrml
    ]);

  emailTemplate = pkgs.writeTextFile {
    name = "email-template.mjml";
    text = ''
      <mjml>
        <mj-head>
          <mj-title>Add to Bag Button Available!</mj-title>
          <mj-attributes>
            <mj-all font-family="Arial, sans-serif" />
            <mj-text font-weight="400" font-size="16px" color="#000000" line-height="24px" />
          </mj-attributes>
          <mj-style>
            .shadow { box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); }
          </mj-style>
        </mj-head>
        <mj-body background-color="#f4f4f4">
          <mj-section background-color="#ffffff" padding="20px 0">
            <mj-column>
              <mj-image src="https://frame.work/favicon.ico" alt="Framework Logo" width="60px" padding-bottom="20px" />
              <mj-text font-size="24px" font-weight="bold" align="center" color="#333333">
                Great News!
              </mj-text>
              <mj-text font-size="18px" align="center" color="#666666" padding-bottom="20px">
                The item you've been waiting for is now available
              </mj-text>
              <mj-button background-color="#0066cc"
                         color="white"
                         font-size="16px"
                         font-weight="bold"
                         border-radius="6px"
                         padding="16px 24px"
                         css-class="shadow"
                         href="{{url}}">
                Shop Now
              </mj-button>
              <mj-text color="#666666" font-size="14px" align="center" padding-top="20px">
                Don't wait too long - items may sell out quickly!
              </mj-text>
            </mj-column>
          </mj-section>
          <mj-section background-color="#f4f4f4" padding="10px 0">
            <mj-column>
              <mj-text color="#666666" font-size="12px" align="center">
                This is an automated notification from your stock checker
              </mj-text>
            </mj-column>
          </mj-section>
        </mj-body>
      </mjml>
    '';
  };

  checkStockScript = pkgs.writeTextFile {
    name = "check-stock.py";
    text = ''
      from playwright.sync_api import sync_playwright
      import os
      import subprocess
      import sys
      import logging
      from datetime import datetime
      from mrml import to_html

      # Configure logging
      log_dir = os.path.expanduser("~/.local/share/check-stock")
      os.makedirs(log_dir, exist_ok=True)
      log_file = os.path.join(log_dir, "check-stock.log")

      logging.basicConfig(
          level=logging.INFO,
          format='%(asctime)s - %(levelname)s - %(message)s',
          handlers=[
              logging.StreamHandler(sys.stdout),
              logging.FileHandler(log_file)
          ]
      )
      logger = logging.getLogger(__name__)

      def send_notification_email(url):
          try:
              # Read and render MJML template
              with open('${emailTemplate}', 'r') as f:
                  mjml_content = f.read()

              # Replace placeholders
              mjml_content = mjml_content.replace('{{url}}', url)

              # Render MJML to HTML
              html_output = to_html(mjml_content)

              email_content = f"""Subject: Add to Bag Button Available!
      To: alex@rosenfeld.one
      Content-Type: text/html; charset=UTF-8
      MIME-Version: 1.0

      {html_output}
      """
              # Send email using msmtp
              process = subprocess.Popen(
                  ['${pkgs.msmtp}/bin/msmtp', 'alex@rosenfeld.one'],
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

      def check_add_to_bag_button(url):
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

                  logger.debug("Looking for 'Add to bag' button")
                  button = page.locator('[data-test-id="add-to-bag-button"]')

                  if button.is_visible():
                      logger.info("'Add to bag' button is visible")
                      send_notification_email(url)
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

          urls = sys.argv[1:]
          logger.info("Starting stock check script")

          for url in urls:
              logger.info(f"Checking URL: {url}")
              check_add_to_bag_button(url)

    '';
  };

  # Define URLs to monitor
  urlsToMonitor = [
    {
      name = "mystery-box-hr2";
      url = "https://frame.work/ca/en/products/framework-mystery-boxes?v=FRANHR0002";
      timerConfig = {
        OnCalendar = "hourly";
      };
    }
    {
      name = "mystery-box-hr1";
      url = "https://frame.work/ca/en/products/framework-mystery-boxes?v=FRANHR0001";
      timerConfig = {
        OnCalendar = "hourly";
      };
    }
  ];

  # Generate systemd services and timers from the URLs
  mkStockService = {
    name,
    url,
    ...
  }: {
    "check-stock-${name}" = {
      serviceConfig = {
        ExecStart = ["${pkgs.check-stock}/bin/check-stock ${url}"];
      };
    };
  };

  mkStockTimer = {
    name,
    timerConfig,
    ...
  }: {
    "check-stock-${name}" = {
      wantedBy = ["timers.target"];
      timerConfig = timerConfig;
    };
  };
in {
  nixpkgs.overlays = [
    (final: prev: {
      check-stock = pkgs.writeShellApplication {
        name = "check-stock";

        runtimeInputs = [
          pkgs.playwright-driver
        ];

        text = ''
          export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
          export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
          ${pythonEnv}/bin/python ${checkStockScript} "$@"
        '';
      };
    })
  ];

  environment.systemPackages = [
    # Add new script for checking all products
    (pkgs.writeShellApplication {
      name = "check-all-stock";
      text = ''
        ${pkgs.check-stock}/bin/check-stock ${lib.concatMapStringsSep " " (item: item.url) urlsToMonitor}
      '';
    })
  ];

  systemd.services = lib.mkMerge (map mkStockService urlsToMonitor);
  systemd.timers = lib.mkMerge (map mkStockTimer urlsToMonitor);
}
