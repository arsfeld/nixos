---
id: task-62
title: Add OctoPrint to r2s
status: To Do
assignee: []
created_date: '2025-10-18 18:04'
labels:
  - service
  - r2s
  - 3d-printing
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure and deploy OctoPrint on the r2s ARM-based router host. OctoPrint is a web interface for 3D printers that allows remote monitoring and control.

This should:
- Add OctoPrint service configuration (likely as a constellation module or host-specific service)
- Configure appropriate ports and networking
- Set up persistent storage for OctoPrint data
- Consider resource constraints of the r2s hardware
- Test deployment to ensure it works on aarch64-linux architecture
<!-- SECTION:DESCRIPTION:END -->
