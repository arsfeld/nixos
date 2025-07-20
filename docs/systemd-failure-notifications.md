# Systemd Failure Notifications in NixOS Configuration

This document provides comprehensive information about the systemd failure notification system used throughout this NixOS configuration for alerting administrators about service failures and system events.

## Overview

The systemd failure notification system provides automated alerts for:
- **Systemd service failures** - Automatic notifications when any service fails
- **System lifecycle events** - Boot and shutdown notifications
- **Backup job status** - Success/failure alerts for backup operations
- **Custom events** - Triggered by scripts and applications
- **Weekly health heartbeats** - Regular system status updates

The system is designed with reliability and observability in mind, featuring:
- **Rate limiting** - Prevents notification spam (1 hour cooldown per service)
- **Beautiful HTML emails** - Rich formatting with system context
- **AI-powered analysis** - Optional crash log analysis using Google Gemini
- **GitHub issue creation** - Automatic issue tracking with duplicate detection

## Architecture

### Core Components

#### 1. send-email-event Package

Located in `packages/send-email-event/`, this is the core utility for sending email notifications.

**Components:**
- `send-email.py` - Main Python script that generates and sends HTML emails
- `event-notification.html` - Jinja2 HTML email template with responsive design
- `analyze-with-llm.py` - Optional AI analysis using Google Gemini API
- `create-github-issue.py` - GitHub issue creation with duplicate detection
- `default.nix` - Nix package definition

**Features:**
- Beautiful HTML emails with gradient hero sections
- Automatic system information collection (CPU, memory, disk, uptime)
- Support for custom event descriptions and additional content
- Command-line interface for easy integration

#### 2. Email Configuration Module

The `modules/constellation/email.nix` module provides basic email functionality:

```nix
constellation.email = {
  enable = true;
  fromEmail = "admin@rosenfeld.one";
  toEmail = "alex@rosenfeld.one";
};
```

This module:
- Configures msmtp as the mail transfer agent
- Sets up authentication with PurelyMail SMTP service
- Creates systemd services for boot/shutdown notifications
- Provides a weekly heartbeat timer

#### 3. Systemd Email Notify Module

The `modules/systemd-email-notify.nix` module automatically sends emails when services fail:

```nix
systemdEmailNotify = {
  enable = true;
  toEmail = "admin@example.com";
  fromEmail = "noreply@example.com";
  enableLLMAnalysis = true;
  googleApiKey = config.age.secrets.google-api-key.path;
  
  # Optional: Enable GitHub issue creation
  enableGitHubIssues = true;
  gitHubRepo = "owner/repo";
  gitHubUpdateInterval = 24;  # hours
};
```

Features:
- Automatically adds `onFailure` handlers to all systemd services
- Rate limiting with 1-hour cooldown between notifications per service
- Includes service logs and status in emails
- Optional AI analysis of crash logs
- Tracks failure counts per service
- Optional GitHub issue creation with duplicate detection
- Intelligent issue updates vs new issue creation based on time interval

## Email Content

### Standard Email Format

All emails follow a consistent format:

1. **Header**: Gradient hero section with event title
2. **Event Details**: Description and any additional content
3. **System Information**:
   - Operating System and kernel version
   - System uptime
   - CPU usage and load averages
   - Memory usage
   - Disk usage for all mounted filesystems
4. **Footer**: Timestamp and hostname

### Service Failure Emails

Additional information for service failures:
- Service name and status
- Exit code and signal (if applicable)
- Recent journal logs (last 50 lines)
- Failure count for the service
- Time since last notification
- Optional AI analysis of the failure

## Configuration

### Basic Email Setup

1. Enable the email module in your host configuration:

```nix
{
  constellation.email = {
    enable = true;
    fromEmail = "noreply@yourdomain.com";
    toEmail = "admin@yourdomain.com";
  };
}
```

2. Configure email credentials in `secrets/secrets.nix`:

```nix
{
  email-password = {
    file = ./email-password.age;
    owner = "send-email";
  };
}
```

3. Encrypt your email password:

```bash
echo -n "your-smtp-password" | agenix -e secrets/email-password.age
```

### Service Failure Notifications

Enable automatic notifications for all systemd service failures:

```nix
{
  systemdEmailNotify = {
    enable = true;
    toEmail = "alerts@yourdomain.com";
    fromEmail = "noreply@yourdomain.com";
    
    # Optional: Enable AI analysis
    enableLLMAnalysis = true;
    googleApiKey = config.age.secrets.google-api-key.path;
    
    # Optional: Customize rate limiting (default: 3600 seconds)
    cooldownSeconds = 7200;  # 2 hours
  };
}
```

### GitHub Issue Integration

The systemd email notify module can automatically create GitHub issues for service failures:

```nix
{
  systemdEmailNotify = {
    enable = true;
    toEmail = "alerts@yourdomain.com";
    fromEmail = "noreply@yourdomain.com";
    
    # Enable GitHub issue creation
    enableGitHubIssues = true;
    gitHubRepo = "yourusername/yourrepo";
    gitHubUpdateInterval = 24;  # hours before creating new issue vs updating
  };
}
```

**Features:**
- Automatic issue creation on service failures
- Duplicate detection to prevent issue spam
- Updates existing issues if failures occur within the update interval
- Automatic labeling based on service type and hostname
- Includes full service status and logs in issue body

**Prerequisites:**
1. Install and authenticate GitHub CLI:
   ```bash
   gh auth login
   ```
2. Ensure the authenticated user has write access to the specified repository

**Issue Format:**
- Title: `[hostname] service-name failed - hash`
- Labels: `systemd-failure`, `host:hostname`, and service-specific labels
- Body: Service status, recent logs, failure count, and optional AI analysis

### Per-Service Configuration

Disable notifications for specific services:

```nix
systemd.services.noisy-service = {
  # ... service configuration ...
  onFailure = lib.mkForce [];  # Remove email notification
};
```

## Testing Email Notifications

### 1. Manual Testing

Send a test email using the command-line tool:

```bash
# Basic test
send-email-event "Test Event" "This is a test notification"

# With custom recipients
send-email-event \
  --email-from "test@example.com" \
  --email-to "admin@example.com" \
  "Test Event" \
  "Additional content for the email"

# With environment variables
EMAIL_TO="admin@example.com" send-email-event "Test" "Message"
```

### 2. Test Service Failures

Create a test service that intentionally fails:

```nix
# In your configuration.nix
systemd.services.email-test-failure = {
  description = "Test service for email notifications";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.bash}/bin/bash -c 'echo \"This service will fail\"; exit 1'";
  };
};
```

Trigger the failure:

```bash
sudo systemctl start email-test-failure
```

### 3. Test System Events

```bash
# Test boot notification (requires reboot)
sudo reboot

# Test heartbeat notification
sudo systemctl start system-heartbeat

# View email logs
sudo journalctl -u email-boot
sudo journalctl -u email-shutdown
sudo journalctl -u system-heartbeat
```

### 4. Debug Email Sending

Check msmtp configuration:

```bash
# Test SMTP connection
echo "Test" | msmtp -debug admin@example.com

# Check msmtp configuration
cat /etc/msmtprc

# View email sending logs
sudo journalctl -f | grep -E "(msmtp|send-email)"
```

## Troubleshooting

### Common Issues

#### 1. Emails Not Sending

**Check SMTP Configuration:**
```bash
# Verify msmtp can connect
msmtp --serverinfo --host=smtp.purelymail.com --port=587

# Check password file permissions
ls -la /run/agenix/email-password
```

**Verify Service Status:**
```bash
# Check if email services are running
systemctl status email-boot
systemctl status email-shutdown
systemctl list-timers | grep heartbeat
```

#### 2. Service Failure Notifications Not Working

**Verify Module is Enabled:**
```bash
# Check if onFailure handlers are added
systemctl show your-service | grep OnFailure
```

**Check Rate Limiting:**
```bash
# View cooldown status
ls -la /tmp/service_failure_*
cat /tmp/service_failure_your-service.timestamp
cat /tmp/service_failure_your-service.count
```

#### 3. AI Analysis Not Working

**Check API Key:**
```bash
# Verify Google API key is accessible
sudo cat /run/agenix/google-api-key

# Test AI analysis manually
analyze-with-llm "Test error message"
```

#### 4. GitHub Issues Not Creating

**Check GitHub CLI Authentication:**
```bash
# Verify gh is authenticated
gh auth status

# Test issue creation manually
echo "Test" | gh issue create --repo owner/repo --title "Test" --body-file -

# Check for existing issues
gh issue list --repo owner/repo --search "systemd-failure"
```

**Debug Issue Creation:**
```bash
# Run create-github-issue manually
create-github-issue \
  --repo "owner/repo" \
  --service "test-service" \
  --hostname "$(hostname)" \
  --status /tmp/test-status.txt \
  --journal /tmp/test-journal.txt \
  --failure-count 1
```

### Log Locations

- Email sending logs: `journalctl -u send-email@*`
- SMTP logs: `journalctl | grep msmtp`
- Service failure notifications: `journalctl -u notify-email@*`
- System event notifications: `journalctl -u email-boot email-shutdown system-heartbeat`

## Integration Examples

### Backup Notifications

The backup system automatically sends emails:

```nix
constellation.backup = {
  enable = true;
  # Email notifications are automatic when email module is enabled
};
```

### Custom Script Integration

```bash
#!/usr/bin/env bash
set -euo pipefail

# Perform some task
if ! do-important-task; then
  send-email-event "Task Failed" "The important task failed with error: $?"
  exit 1
fi

send-email-event "Task Completed" "Successfully completed the important task"
```

### Monitoring Integration

Configure Prometheus Alertmanager to use the email system:

```nix
services.prometheus.alertmanager = {
  configuration = {
    route.receiver = "email";
    receivers = [{
      name = "email";
      email_configs = [{
        to = config.constellation.email.toEmail;
        from = config.constellation.email.fromEmail;
        smarthost = "smtp.purelymail.com:587";
        auth_username = config.constellation.email.fromEmail;
        auth_password_file = config.age.secrets.email-password.path;
      }];
    }];
  };
};
```

## Security Considerations

1. **Password Storage**: Email passwords are encrypted using agenix and only decrypted at runtime
2. **Access Control**: The send-email user has minimal privileges
3. **Rate Limiting**: Prevents notification flooding and potential email abuse
4. **Input Validation**: The send-email-event script validates inputs to prevent injection
5. **Network Security**: All SMTP connections use TLS encryption

## Best Practices

1. **Use Descriptive Event Names**: Make it easy to identify issues from email subjects
2. **Include Relevant Context**: Add helpful information in the message body
3. **Test Before Production**: Always test email notifications in development first
4. **Monitor Email Delivery**: Set up monitoring for the email system itself
5. **Rotate Credentials**: Periodically update SMTP passwords
6. **Customize Templates**: Modify the HTML template to match your organization's branding

## Advanced Configuration

### Complete Feature Example

Here's an example configuration that enables all features - email notifications, AI analysis, and GitHub issue creation:

```nix
{
  # Basic email configuration
  constellation.email = {
    enable = true;
    fromEmail = "noreply@yourdomain.com";
    toEmail = "admin@yourdomain.com";
  };

  # Service failure notifications with all features
  systemdEmailNotify = {
    enable = true;
    toEmail = "alerts@yourdomain.com";
    fromEmail = "noreply@yourdomain.com";
    
    # Enable AI-powered failure analysis
    enableLLMAnalysis = true;
    googleApiKey = config.age.secrets.google-api-key.path;
    
    # Enable GitHub issue creation
    enableGitHubIssues = true;
    gitHubRepo = "yourusername/infrastructure";
    gitHubUpdateInterval = 24;  # Create new issue after 24 hours
  };

  # Required secrets
  age.secrets = {
    email-password = {
      file = ./secrets/email-password.age;
      owner = "send-email";
    };
    google-api-key = {
      file = ./secrets/google-api-key.age;
      mode = "0400";
    };
  };
}
```

This configuration will:
1. Send an email for every service failure (with 1-hour rate limiting)
2. Include AI analysis of the failure in the email
3. Create a GitHub issue for tracking and collaboration
4. Update existing issues if the service fails again within 24 hours

### Custom Email Templates

Create a custom template:

```html
<!-- /etc/email-templates/custom.html -->
<!DOCTYPE html>
<html>
<head>
    <style>
        /* Your custom styles */
    </style>
</head>
<body>
    <h1>{{ title }}</h1>
    <p>{{ description }}</p>
    <!-- System info is available as: {{ system_info }} -->
</body>
</html>
```

Use the custom template:

```bash
EMAIL_TEMPLATE=/etc/email-templates/custom.html \
  send-email-event "Custom Event" "With custom template"
```

### Multiple Recipients

While the system is designed for single recipients, you can work around this:

```bash
# Send to multiple recipients
for email in admin1@example.com admin2@example.com; do
  EMAIL_TO="$email" send-email-event "Alert" "Important notification"
done
```

### Conditional Notifications

Only send emails for critical services:

```nix
systemd.services = lib.mapAttrs (name: service:
  if lib.hasPrefix "critical-" name
  then service
  else service // { onFailure = lib.mkForce []; }
) config.systemd.services;
```

## Conclusion

The email notification system provides a robust foundation for system observability and alerting. By following this guide, you can ensure reliable notifications for system events and service failures, helping maintain system health and quick incident response.

For additional help or to report issues, please refer to the repository's issue tracker.