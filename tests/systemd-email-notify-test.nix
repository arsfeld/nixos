# Test for systemd email notification system
# This test verifies that email notifications are sent when services fail
{
  name = "systemd-email-notify";

  nodes = {
    machine = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [
        ../modules/systemd-email-notify.nix
      ];

      # Configure email notifications
      systemdEmailNotify = {
        toEmail = "test@example.com";
        fromEmail = "alerts@example.com";
        enableLLMAnalysis = false; # Disable LLM for testing
        enableGitHubIssues = true;
        gitHubRepo = "test/repo";
      };

      # Create a test service that fails periodically
      systemd.services.email-notify-test = {
        description = "Test service that fails periodically to verify email notifications";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/false";
        };
      };

      systemd.timers.email-notify-test = {
        description = "Timer to trigger email notification test service failure";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "20min";
          Unit = "email-notify-test.service";
        };
      };

      # Mock msmtp to capture emails
      environment.systemPackages = with pkgs; [
        (writeShellScriptBin "msmtp" ''
          # Mock msmtp that logs emails to a file
          echo "=== EMAIL START ===" >> /tmp/captured-emails.log
          cat >> /tmp/captured-emails.log
          echo -e "\n=== EMAIL END ===" >> /tmp/captured-emails.log
          echo "Email captured successfully"
        '')

        # Mock gh CLI for GitHub issue creation
        (writeShellScriptBin "gh" ''
          # Mock gh that logs commands to a file
          echo "=== GH COMMAND ===" >> /tmp/gh-commands.log
          echo "Command: $@" >> /tmp/gh-commands.log

          # Handle different gh commands
          case "$1" in
            "issue")
              case "$2" in
                "list")
                  # Return empty list for issue searches
                  echo "[]"
                  ;;
                "create")
                  # Log the issue creation
                  echo "Title: $4" >> /tmp/gh-commands.log
                  echo "Body: $6" >> /tmp/gh-commands.log
                  echo "https://github.com/test/repo/issues/123"
                  ;;
                "comment")
                  # Log the comment
                  echo "Issue: $4" >> /tmp/gh-commands.log
                  echo "Comment: $6" >> /tmp/gh-commands.log
                  ;;
              esac
              ;;
          esac
          echo "=== GH END ===" >> /tmp/gh-commands.log
        '')
      ];

      # Override the send-email-event package to use our mock binaries
      nixpkgs.overlays = [
        (self: super: {
          send-email-event = super.send-email-event.overrideAttrs (old: {
            propagatedBuildInputs =
              (old.propagatedBuildInputs or [])
              ++ [
                pkgs.figlet
              ];
            postFixup = ''
              # Ensure our mock msmtp is used
              wrapProgram $out/bin/send-email-event \
                --prefix PATH : ${lib.makeBinPath [
                (pkgs.writeShellScriptBin "msmtp" ''
                  echo "=== EMAIL START ===" >> /tmp/captured-emails.log
                  cat >> /tmp/captured-emails.log
                  echo -e "\n=== EMAIL END ===" >> /tmp/captured-emails.log
                '')
              ]}

              # Wrap create-github-issue if it exists
              if [ -f $out/bin/create-github-issue ]; then
                wrapProgram $out/bin/create-github-issue \
                  --prefix PATH : ${lib.makeBinPath [
                (pkgs.writeShellScriptBin "gh" ''
                  echo "=== GH COMMAND ===" >> /tmp/gh-commands.log
                  echo "Command: $@" >> /tmp/gh-commands.log
                  case "$1" in
                    "issue")
                      case "$2" in
                        "list") echo "[]" ;;
                        "create") echo "https://github.com/test/repo/issues/123" ;;
                      esac
                      ;;
                  esac
                  echo "=== GH END ===" >> /tmp/gh-commands.log
                '')
              ]}
              fi
            '';
          });
        })
      ];
    };
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    # Create log files
    machine.succeed("touch /tmp/captured-emails.log /tmp/gh-commands.log")
    machine.succeed("chmod 666 /tmp/captured-emails.log /tmp/gh-commands.log")

    # Wait for the timer to be active
    machine.wait_for_unit("email-notify-test.timer")

    # Manually trigger the test service to fail immediately
    machine.fail("systemctl start email-notify-test.service")

    # Wait a bit for the email notification to be processed
    machine.sleep(5)

    # Check that an email was captured
    machine.succeed("test -f /tmp/captured-emails.log")
    email_output = machine.succeed("cat /tmp/captured-emails.log")

    # Verify the email contains expected content
    assert "Service Failure email-notify-test" in email_output, "Email should contain service failure notification"
    assert "Failed Service: email-notify-test" in email_output, "Email should contain the failed service name"
    assert "test@example.com" in email_output, "Email should be sent to the configured address"
    assert "alerts@example.com" in email_output, "Email should be from the configured address"

    # Check GitHub issue creation
    gh_output = machine.succeed("cat /tmp/gh-commands.log || echo 'No GitHub commands logged'")
    print(f"GitHub commands: {gh_output}")

    if "test/repo" in config.systemdEmailNotify.gitHubRepo:
        assert "issue" in gh_output, "Should attempt to create GitHub issue"
        assert "create" in gh_output or "comment" in gh_output, "Should create issue or comment"

    # Test rate limiting: trigger the service again
    machine.fail("systemctl start email-notify-test.service")
    machine.sleep(2)

    # Count how many emails were sent (should be only 1 due to rate limiting)
    email_count = machine.succeed("grep -c '=== EMAIL START ===' /tmp/captured-emails.log || echo 0").strip()
    assert email_count == "1", f"Expected 1 email due to rate limiting, but got {email_count}"

    # Test cooldown period expiry (simulate by modifying timestamp file)
    machine.succeed("echo '0' > /tmp/service_failure_email-notify-test.timestamp")

    # Trigger again after cooldown
    machine.fail("systemctl start email-notify-test.service")
    machine.sleep(2)

    # Should now have 2 emails
    email_count = machine.succeed("grep -c '=== EMAIL START ===' /tmp/captured-emails.log || echo 0").strip()
    assert email_count == "2", f"Expected 2 emails after cooldown, but got {email_count}"

    # Verify failure count in second email
    email_output = machine.succeed("cat /tmp/captured-emails.log")
    assert "Failure #2" in email_output, "Second email should show failure count #2"

    # Print captured emails for debugging
    print("=== Captured Emails ===")
    print(email_output)
    print("=== End Emails ===")
  '';
}
