# LLM-Powered Crash Log Analysis

This guide explains how to enable AI-powered analysis of systemd service failures in your NixOS configuration.

## Overview

When enabled, the system will automatically analyze crash logs using Google's Gemini AI and include intelligent insights in failure notification emails. The analysis includes:

- Brief summary of what went wrong
- Likely root cause identification
- Specific steps to resolve the issue

## Setup Instructions

### 1. Get a Google AI Studio API Key

Since Google AI Studio doesn't provide CLI commands for API key creation, you need to:

1. Visit [Google AI Studio](https://aistudio.google.com/apikey)
2. Sign in with your Google account
3. Click "Create API Key"
4. Copy the generated API key

**Note**: Google provides 6,000,000 tokens/day free with Gemini 2.5 Flash.

### 2. Configure Your NixOS System

There are two ways to configure the Google API key:

#### Option A: Using Agenix (Recommended)

1. First, create a temporary file with your API key:
   ```bash
   echo "YOUR_API_KEY_HERE" > /tmp/google-api-key.txt
   ```

2. Encrypt it using the just command:
   ```bash
   cd secrets && agenix -e google-api-key.age < /tmp/google-api-key.txt
   rm -f /tmp/google-api-key.txt
   ```

   Alternatively, you can use the interactive editor:
   ```bash
   cd secrets && agenix -e google-api-key.age
   # This will open your editor - paste the API key and save
   ```

3. Configure your NixOS system:
   ```nix
   {
     # Enable the systemd email notifications
     imports = [ ./modules/systemd-email-notify.nix ];

     # Configure agenix secret
     age.secrets.google-api-key.file = ./secrets/google-api-key.age;

     # Configure email notifications with LLM analysis
     systemdEmailNotify = {
       toEmail = "admin@example.com";
       fromEmail = "noreply@example.com";
       
       # Enable LLM analysis
       enableLLMAnalysis = true;
       googleApiKey = config.age.secrets.google-api-key.path;
     };
   }
   ```

#### Option B: Direct Configuration (Less Secure)

```nix
{
  # Enable the systemd email notifications
  imports = [ ./modules/systemd-email-notify.nix ];

  # Configure email notifications with LLM analysis
  systemdEmailNotify = {
    toEmail = "admin@example.com";
    fromEmail = "noreply@example.com";
    
    # Enable LLM analysis
    enableLLMAnalysis = true;
    googleApiKey = "YOUR_GOOGLE_API_KEY_HERE";  # Not recommended for production
  };
}
```

**Note**: The module automatically detects whether the `googleApiKey` is a file path (agenix) or a direct string.

### 3. Test the Configuration

You can test the analysis by manually triggering a service failure:

```bash
# Create a test service that will fail
sudo systemctl start some-failing-service

# Check the email notification
```

## Example Output

When a service fails, you'll receive an email with:

1. **Standard Information**:
   - Service name and failure count
   - Full service status
   - Recent journal logs

2. **AI Analysis** (new):
   ```
   AI Analysis
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   Summary: The nginx service failed to start due to a configuration error. 
   The server block on line 42 has a duplicate location directive that 
   conflicts with an earlier definition.

   Root Cause: Duplicate location /api block in nginx configuration file
   at /etc/nginx/sites-enabled/myapp.conf

   Resolution Steps:
   1. Edit /etc/nginx/sites-enabled/myapp.conf and remove the duplicate 
      location block at line 42
   2. Run 'nginx -t' to validate the configuration
   3. Restart the service with 'systemctl restart nginx'
   ```

## Free Tier Limits

Google's Gemini API free tier includes:
- **6,000,000 tokens per day**
- **250,000 tokens per minute**

This is more than sufficient for analyzing crash logs, as each analysis typically uses only 500-2000 tokens.

## Using Constellation Module (Recommended for Multiple Hosts)

To enable LLM analysis across all your Constellation hosts, simply enable the `llmEmail` module:

```nix
# In your host configuration (e.g., hosts/storage/configuration.nix)
{
  # Enable both email notifications and LLM analysis
  constellation.email.enable = true;  # Usually already enabled
  constellation.llmEmail.enable = true;
}
```

This will automatically:
- Configure agenix secret for the Google API key
- Enable systemd email notifications with LLM analysis
- Use the email addresses from `constellation.email` configuration

The module expects the Google API key to be encrypted at `secrets/google-api-key.age`.

## Troubleshooting

### API Key Not Working
- Ensure the API key is correctly set in your configuration
- Check that the key has access to the Gemini API
- Verify your Google Cloud project has the Generative AI API enabled

### No Analysis in Email
- Check if `enableLLMAnalysis` is set to `true`
- Look for errors in the system journal: `journalctl -u email@*.service`
- Ensure the `google-generativeai` Python package is available

### Rate Limiting
- The email system has a 1-hour cooldown between notifications for the same service
- This prevents spam and excessive API usage