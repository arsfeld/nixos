---
id: task-63
title: Fix OctoPi boot failure (constant red light)
status: To Do
assignee: []
created_date: '2025-10-18 18:09'
labels:
  - bug
  - hardware
  - octopi
  - raspberry-pi
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OctoPi device is not booting. Symptoms:
- Constant red light
- Never completes boot process
- Unable to access system

Potential causes to investigate:
- SD card corruption or failure
- Power supply insufficient or failing
- Boot partition issues
- Hardware failure (Raspberry Pi)
- Firmware/bootloader corruption

Troubleshooting steps:
1. Check SD card on another system (verify filesystem integrity)
2. Test with known good power supply (need 5V 2.5A+ for Pi 3, 3A+ for Pi 4)
3. Try booting from known good SD card image
4. Check for hardware damage or loose connections
5. Review boot logs if accessible via serial console
6. Consider re-imaging SD card with fresh OctoPi image
7. Test Raspberry Pi with different OS to rule out hardware failure
<!-- SECTION:DESCRIPTION:END -->
