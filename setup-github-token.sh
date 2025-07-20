#!/usr/bin/env bash
# Script to set up GitHub token for agenix

set -euo pipefail

echo "GitHub Token Setup for NixOS Constellation"
echo "=========================================="
echo
echo "This script will help you create an encrypted GitHub token for use with"
echo "systemd failure notifications."
echo
echo "You'll need a GitHub Personal Access Token with the following permissions:"
echo "  - repo (Full control of private repositories)"
echo "    OR at minimum:"
echo "    - public_repo (Access to public repositories)"
echo "    - write:issues (Create and comment on issues)"
echo
echo "To create a token:"
echo "1. Go to https://github.com/settings/tokens/new"
echo "2. Give it a descriptive name (e.g., 'NixOS SystemD Notifications')"
echo "3. Select the required scopes"
echo "4. Generate the token and copy it"
echo
read -p "Do you have your GitHub token ready? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Please create a token first, then run this script again."
    exit 1
fi

echo
echo "Please paste your GitHub token (input will be hidden):"
read -s GITHUB_TOKEN

if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: Token cannot be empty"
    exit 1
fi

# Create the encrypted file
echo -n "$GITHUB_TOKEN" | agenix -e secrets/github-token.age

echo
echo "GitHub token has been encrypted and saved to secrets/github-token.age"
echo
echo "To enable GitHub issue creation for systemd failures, add this to your host configuration:"
echo
echo "  constellation.githubNotify.enable = true;"
echo
echo "The system will automatically:"
echo "- Configure gh CLI with your token"
echo "- Create GitHub issues when services fail"
echo "- Prevent duplicate issues by updating existing ones"