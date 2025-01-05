{
  lib,
  pkgs,
  ...
}: let
  pythonEnv = pkgs.python3.withPackages (ps:
    with ps; [
      jinja2
      (ps.buildPythonPackage rec {
        pname = "mrml";
        version = "0.1.15";
        format = "pyproject";

        src = pkgs.fetchPypi {
          inherit pname version;
          sha256 = "sha256-XbYRkJ6tptG0LUYZQAF5UsHjpm9ys2graxDmn1BUz6A=";
        };

        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustPlatform.cargoSetupHook
          pkgs.rustc
        ];

        build-system = [
          pkgs.rustPlatform.maturinBuildHook
        ];

        cargoDeps = pkgs.rustPlatform.fetchCargoTarball {
          inherit src;
          name = "${pname}-${version}";
          hash = "sha256-5cEQMCWM473y+se6jWuWr/T9Pg/Q6BuD4ypGF1SBF6M=";
        };

        doCheck = false;
        propagatedBuildInputs = [];
      })
    ]);

  sendEmailScript = pkgs.writeTextFile {
    name = "sendEmailEvent.py";
    text = ''
      import subprocess
      import datetime
      import os
      import socket
      from jinja2 import Template
      from mrml import to_html

      def get_command_output(command):
          try:
              return subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT).decode('utf-8').strip()
          except subprocess.CalledProcessError as e:
              return f"Error executing command: {e.output.decode('utf-8').strip()}"
          except Exception as e:
              return f"Unexpected error: {str(e)}"

      def send_email_event(event, extra_content=""):
          hostname = socket.gethostname()
          current_date = datetime.datetime.now().isoformat()
          figlet_output = get_command_output(f"${pkgs.figlet}/bin/figlet -f slant '{hostname}'")
          system_info = {
              "OS": get_command_output("${pkgs.coreutils}/bin/uname -s"),
              "Kernel": get_command_output("${pkgs.coreutils}/bin/uname -r"),
              "Uptime": get_command_output("${pkgs.procps}/bin/uptime"),
              "CPU": get_command_output("${pkgs.util-linux}/bin/lscpu | ${pkgs.gnugrep}/bin/grep 'Model name' | ${pkgs.coreutils}/bin/cut -f 2 -d ':'"),
              "Memory": get_command_output("${pkgs.procps}/bin/free -h | ${pkgs.gawk}/bin/awk '/^Mem:/ {print $2 \" total, \" $3 \" used, \" $4 \" free\"}'"),
              "Disk": get_command_output("${pkgs.coreutils}/bin/df -h / | ${pkgs.gawk}/bin/awk 'NR==2 {print $2 \" total, \" $3 \" used, \" $4 \" free\"}'"),
          }

          subject = f"[{hostname}] {event} {current_date}"

          with open('${./event-notification.mjml}', 'r') as f:
              mjml_template = f.read()

          try:
              template = Template(mjml_template)
              mjml_content = template.render(
                  FIGLET_OUTPUT=figlet_output,
                  EVENT=event,
                  HOSTNAME=hostname,
                  CURRENT_DATE=current_date,
                  SYSTEM_INFO=system_info,
                  EXTRA_CONTENT=extra_content
              )
          except Exception as e:
              mjml_content = '<mjml><mj-body><mj-section><mj-column><mj-text>Failed to generate MJML content. Please check the system logs for more information.</mj-text></mj-column></mj-section></mj-body></mjml>'
              print(f"Error generating MJML content: {e}")

          # Convert MJML to HTML using Python
          try:
              html_content = to_html(mjml_content)
          except Exception as e:
              print(f"Error: MJML conversion failed. Sending plain text email instead. Error: {e}")
              print(f"Content: {mjml_content}")
              html_content = f"""
              <html>
                <body>
                  <h1>System Event Notification</h1>
                  <h2>{event}</h2>
                  <pre>{figlet_output}</pre>
                  <p>Hostname: {hostname}</p>
                  <p>Date: {current_date}</p>
                  <h3>System Information:</h3>
                  <pre>{fastfetch_output}</pre>
                  {'<h3>Extra Content:</h3><p>' + extra_content + '</p>' if extra_content else '''}
                </body>
              </html>
              """

          # Construct email content
          email_content = f"""From: admin@rosenfeld.one
      To: alex@rosenfeld.one
      Subject: {subject}
      Content-Type: text/html; charset="utf-8"

      {html_content}
      """

          # Send the email using msmtp
          try:
              subprocess.run(
                  ["${pkgs.msmtp}/bin/msmtp", "-t"],
                  input=email_content,
                  text=True,
                  check=True
              )
              print("Email sent successfully")
          except subprocess.CalledProcessError as e:
              print(f"Failed to send email: {e}")

      if __name__ == "__main__":
          import sys
          event = sys.argv[1] if len(sys.argv) > 1 else "Unknown Event"
          extra_content = sys.argv[2] if len(sys.argv) > 2 else ""
          send_email_event(event, extra_content)
    '';
  };
in
  {
    event,
    extraContent ? "",
  }: ''
    ${pythonEnv}/bin/python ${sendEmailScript} "${event}" "${extraContent}"
  ''
