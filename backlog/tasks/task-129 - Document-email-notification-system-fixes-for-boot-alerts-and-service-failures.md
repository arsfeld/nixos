---
id: task-129
title: Document email notification system fixes for boot alerts and service failures
status: Done
assignee: []
created_date: '2025-11-02 11:52'
labels:
  - documentation
  - email
  - constellation
  - bugfix
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fixed multiple issues preventing email notifications from being delivered:

**Issues Found:**
1. Boot/shutdown email alerts failed due to DNS not being ready at boot time (couldn't resolve smtp.purelymail.com)
2. Service failure email notifications failed with "status=3/NOTIMPLEMENTED" due to missing hostname command in PATH
3. isponsorblock and watchyourlan services were crash-looping and generating excessive log noise

**Fixes Applied:**
1. Updated constellation.email module to wait for network-online.target instead of network.target for boot/shutdown alerts
2. Added nettools, coreutils, and util-linux packages to email@ service PATH in systemd-email-notify module
3. Disabled isponsorblock (crash-loop: missing device config) and watchyourlan (recurring exit status 1 errors)

**Files Modified:**
- modules/constellation/email.nix - network-online.target dependency
- modules/systemd-email-notify.nix - PATH configuration with required tools
- hosts/storage/configuration.nix - disabled isponsorblock
- hosts/storage/services/misc.nix - commented out watchyourlan

**Verification:**
- Boot email sent successfully after deployment
- All services have onFailure handlers configured
- email@ service has complete tool PATH including hostname command

Commit: 8ef5679 "fix(constellation): fix email notification system"
<!-- SECTION:DESCRIPTION:END -->
