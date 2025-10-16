---
id: task-43
title: Configure centralized alerting rules on storage observability hub
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:46'
labels:
  - observability
  - alerting
  - prometheus
  - notifications
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up Alertmanager and alert rules on the storage host to monitor all infrastructure and send notifications for critical issues.

## Alert Rules to Implement
- Disk space (warning: 80%, critical: 90%)
- Memory usage (warning: 85%, critical: 95%)
- CPU usage (sustained high usage)
- Service down (any monitored service)
- Host unreachable (no metrics for 5 min)
- High error rate in logs
- Temperature warnings
- Filesystem read-only

## Alertmanager Setup
- Configure notification channels (ntfy, email)
- Set up alert grouping and inhibition rules
- Configure repeat intervals
- Critical alerts: 15min repeat
- Warning alerts: 1 hour repeat

## Integration
- Add Alertmanager to observability-hub module
- Create alert rules file
- Provision Alertmanager datasource in Grafana
- Test alert delivery

## Reference
- Use router's alerting.nix as template (very well done)
- Adapt thresholds for different host types
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Alertmanager configured in observability-hub module
- [x] #2 Alert rules created for critical infrastructure metrics
- [x] #3 Notification channels configured (ntfy and/or email)
- [x] #4 Alert grouping and inhibition rules set up
- [x] #5 Test alerts successfully delivered
- [x] #6 Alertmanager datasource added to Grafana
<!-- AC:END -->
