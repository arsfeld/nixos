{
  lib,
  pkgs,
}: let
  toEmail = "alex@rosenfeld.one";
  mrmlWrapper = pkgs.callPackage ./mrml-wrapper {};
  mjml2html = pkgs.writeScript "mjml2html.sh" ''
    #!${pkgs.stdenv.shell}
    ${mrmlWrapper}/bin/mrml-wrapper
  '';
in
  {
    event,
    extraContent ? "",
  }: ''
      subject="[$(${pkgs.nettools}/bin/hostname)] ${event} $(${pkgs.coreutils}/bin/date --iso-8601=seconds)"
      mjml_content=$(cat <<EOF
    <mjml>
      <mj-head>
        <mj-title>System Event Notification</mj-title>
        <mj-font name="Arial" href="https://fonts.googleapis.com/css?family=Arial" />
      </mj-head>
      <mj-body background-color="#f0f0f0">
        <mj-section>
          <mj-column>
            <mj-text font-family="monospace" font-size="12px" color="#333333" align="center">
              <pre>$(${pkgs.figlet}/bin/figlet -f slant $(${pkgs.nettools}/bin/hostname))</pre>
            </mj-text>
          </mj-column>
        </mj-section>

        <mj-section background-color="#ffffff" border-radius="10px">
          <mj-column>
            <mj-text font-size="24px" color="#2c3e50" font-weight="bold">Event Details</mj-text>
            <mj-text><strong>Event:</strong> ${event}</mj-text>
            <mj-text><strong>Hostname:</strong> $(${pkgs.nettools}/bin/hostname)</mj-text>
            <mj-text><strong>Date:</strong> $(${pkgs.coreutils}/bin/date --iso-8601=seconds)</mj-text>
          </mj-column>
        </mj-section>

        <mj-spacer height="20px" />

        <mj-section background-color="#ffffff" border-radius="10px">
          <mj-column>
            <mj-text font-size="24px" color="#2c3e50" font-weight="bold">System Information</mj-text>
            <mj-text font-family="monospace" font-size="12px" background-color="#f8f8f8" padding="10px">
              <pre>$(${pkgs.neofetch}/bin/neofetch --stdout)</pre>
            </mj-text>
          </mj-column>
        </mj-section>

        <mj-spacer height="20px" />

        ${
      if extraContent != ""
      then ''
        <mj-section background-color="#ffffff" border-radius="10px">
          <mj-column>
            <mj-text font-size="24px" color="#2c3e50" font-weight="bold">Additional Information</mj-text>
            <mj-text font-family="monospace" font-size="12px" background-color="#f8f8f8" padding="10px">
              <pre>${extraContent}</pre>
            </mj-text>
          </mj-column>
        </mj-section>
        <mj-spacer height="20px" />

      ''
      else ""
    }

      </mj-body>
    </mjml>
    EOF
    )

      html_content=$(echo "$mjml_content" | ${mjml2html})

      ${pkgs.coreutils}/bin/cat <<EOF | ${pkgs.msmtp}/bin/msmtp -a default ${toEmail}
    Subject: $subject
    Content-Type: text/html; charset=UTF-8
    MIME-Version: 1.0

    $html_content
    EOF
  ''
