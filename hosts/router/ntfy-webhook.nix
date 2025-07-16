{
  config,
  lib,
  pkgs,
  ...
}: let
  # Create a webhook proxy that formats Alertmanager alerts for ntfy
  python3WithPackages = pkgs.python3.withPackages (ps: with ps; []);

  ntfyWebhookScript = pkgs.writeScript "ntfy-webhook" ''
    #!${python3WithPackages}/bin/python3
    import json
    import sys
    import urllib.request
    import urllib.parse
    import hashlib
    import datetime
    import time
    from http.server import HTTPServer, BaseHTTPRequestHandler

    NTFY_URL = "${config.router.alerting.ntfyUrl}"

    class WebhookHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)

            try:
                data = json.loads(post_data.decode('utf-8'))

                # Process each alert
                for alert in data.get('alerts', []):
                    status = alert.get('status', 'unknown')
                    labels = alert.get('labels', {})
                    annotations = alert.get('annotations', {})

                    # Determine emoji and priority based on severity
                    severity = labels.get('severity', 'info')
                    if severity == 'critical':
                        emoji = '🚨'
                        priority = '5'
                        tags = 'rotating_light,warning'
                    elif severity == 'warning':
                        emoji = '⚠️'
                        priority = '4'
                        tags = 'warning'
                    else:
                        emoji = 'ℹ️'
                        priority = '2'
                        tags = 'information_source'

                    # Format the title (avoid emojis in headers)
                    if status == 'resolved':
                        title = f"RESOLVED: {labels.get('alertname', 'Alert')}"
                        tags = 'white_check_mark'
                    else:
                        title = f"{severity.upper()}: {labels.get('alertname', 'Alert')}"

                    # Format the message
                    summary = annotations.get('summary', 'No summary available')
                    description = annotations.get('description', "")

                    # Add emoji to message body
                    if status == 'resolved':
                        message = f"✅ {summary}"
                    else:
                        message = f"{emoji} {summary}"

                    if description and description != summary:
                        message += f"\n\n{description}"

                    # Add instance info if available
                    instance = labels.get('instance', "")
                    if instance and instance != 'localhost:9090':
                        message += f"\n\nInstance: {instance}"

                    # Send to ntfy
                    headers = {
                        'Title': title,
                        'Priority': priority,
                        'Tags': tags,
                    }

                    # Add actions for alert management
                    if status != 'resolved':
                        # Create silence URLs using the working format
                        # Build the filter string with all available labels
                        filter_parts = []
                        for key, value in labels.items():
                            if key in ['alertname', 'device', 'instance', 'job', 'severity']:
                                filter_parts.append(f'{key}="{value}"')

                        # Join with commas and spaces
                        filter_string = ', '.join(filter_parts)

                        # URL encode the filter for the silencer
                        filter_encoded = urllib.parse.quote('{' + filter_string + '}')

                        # Create URLs for actions
                        silence_url = f"http://router.bat-boa.ts.net:9093/#/silences/new?filter={filter_encoded}"
                        alertmanager_url = f"http://router.bat-boa.ts.net:9093/#/alerts"
                        grafana_url = f"http://router.bat-boa.ts.net:3000"

                        # Add URLs to message body instead of Actions header
                        message += f"\\n\\nSilence: {silence_url}"
                        message += f"\\nAlerts: {alertmanager_url}"
                        message += f"\\nGrafana: {grafana_url}"

                    req = urllib.request.Request(
                        NTFY_URL,
                        data=message.encode('utf-8'),
                        headers=headers
                    )

                    try:
                        urllib.request.urlopen(req)
                    except Exception as e:
                        print(f"Failed to send to ntfy: {e}", file=sys.stderr)

                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'OK')

            except Exception as e:
                print(f"Error processing webhook: {e}", file=sys.stderr)
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'Error')

        def log_message(self, format, *args):
            # Suppress access logs
            pass

    if __name__ == '__main__':
        try:
            server = HTTPServer(('127.0.0.1', 9095), WebhookHandler)
            print("ntfy webhook proxy listening on port 9095", flush=True)
            server.serve_forever()
        except Exception as e:
            print(f"Failed to start server: {e}", file=sys.stderr)
            sys.exit(1)
  '';
in {
  config = lib.mkIf (config.router.alerting.enable && config.router.alerting.ntfyUrl != null) {
    # Create dedicated user for the service
    users.users.ntfy-webhook = {
      isSystemUser = true;
      group = "ntfy-webhook";
      description = "ntfy webhook proxy user";
    };

    users.groups.ntfy-webhook = {};

    # Run the ntfy webhook proxy service
    systemd.services.ntfy-webhook-proxy = {
      description = "ntfy webhook proxy for Alertmanager";
      after = ["network.target" "alertmanager.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = ntfyWebhookScript;
        Restart = "always";
        RestartSec = "10s";
        User = "ntfy-webhook";
        Group = "ntfy-webhook";

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;

        # Network access
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];

        # Remove unnecessary capabilities since we're binding to port 9095 (>1024)
        # AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        # CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
    };
  };
}
