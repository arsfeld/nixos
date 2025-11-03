---
id: task-131
title: Update README documentation to reflect current repository state
status: Done
assignee: []
created_date: '2025-11-02 12:00'
updated_date: '2025-11-02 13:08'
labels:
  - documentation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The README.md file is currently out of date and needs to be updated to accurately reflect the current state of the repository, including:

- Current architecture (dual-tunnel setup, split-horizon DNS, etc.)
- Updated service configurations (Media Gateway architecture, constellation modules)
- Secret management migration status (sops-nix on cloud, ragenix legacy on other hosts)
- Deployment workflows (deploy-rs and Colmena usage)
- Key configuration patterns and directory structure
- Service access patterns (*.arsfeld.one split-horizon, *.bat-boa.ts.net Tailscale)

The CLAUDE.md file contains comprehensive information that should be reflected in user-facing README documentation.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Review current README.md and identify outdated sections
2. Update architecture section with dual-tunnel, split-horizon DNS
3. Update secret management section to reflect sops-nix migration
4. Add constellation modules documentation
5. Update service access patterns documentation
6. Update deployment section with both deploy-rs and Colmena
7. Fix outdated host list
8. Test build after changes
9. Commit with proper conventional commit message
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Completed concise README.md rewrite in commit a921814 (amended)

First attempt was too verbose and instruction-heavy - treated it like a manual

Investigated actual host purposes by reading configuration files:

- Infrastructure: storage (NAS), cloud (gateway), cottage (secondary server), micro (mail), routers

- Embedded: octopi (3D printing), raspi3

- Cloud: cloud-br (Oracle), core (minimal), hpe (virtualization)

- Desktops: raider, g14, striker

Final README is now concise, public-facing overview:

- Brief system categorization

- High-level feature list

- Quick start commands only

- References CLAUDE.md for detailed instructions

- 85 lines vs 390 lines (78% reduction)

Added hardware specifications to README in commit 79642f6

SSH'd into all hosts to check status and gather specs:

Online (5): storage, cloud, router, r2s, raider

Offline (9): cottage, micro, octopi, raspi3, cloud-br, core, hpe, g14, striker

Gathered concise specs: CPU model, core/thread count, RAM

Hardware highlights:

- storage: Intel 13th gen 12c/24t, 32GB (main NAS)

- cloud: ARM Neoverse 4c, 24GB (gateway proxy)

- router: Intel N5105 4c, 8GB

- r2s: Rockchip RK3328 4c, 1GB (ARM router)

- raider: Intel i5-12500H 16t, 32GB (laptop)

Fixed incorrect descriptions in commit 052b8a1:

- raider: Corrected from 'MSI Raider laptop' to 'ITX desktop'

- ERYING G660 ITX board (Chinese brand using laptop CPUs)

- Intel i5-12500H (laptop CPU, 12c/24t)

- AMD RX 6650 XT desktop GPU

- 32GB RAM, dual NVMe (500GB + 2TB)

- r2s: Added that it's not just a router but also runs Home Assistant

Final README accurately reflects hardware and purpose of all systems

Added tasteful emojis in commit a75a063:

- Section headers: 💻 🏗️ ✨ 🚀 📁 🔧 📚 📄

- Host-specific emojis: 💾 storage, ☁️ cloud, 🏡 cottage, 📧 micro, 🔀 router, 🏠 r2s (home automation), 🖨️ octopi (3D printer), 🍓 raspi3, 🎮 raider/striker (gaming), 💻 g14 (laptop)

- Feature emojis: 🧩 modular, 🌍 DNS, 🚀 deployment, 🔐 secrets, 📦 caching, 🔨 builders, 📝 declarative

- Maintains professional tone while improving visual navigation and scannability

README now complete with accurate hardware specs, online status, and tasteful visual enhancements

Squashed all 4 README commits into single commit 45f4910

Previous commits (a921814, 79642f6, 052b8a1, a75a063) combined into one comprehensive commit

Clean commit history with all README changes documented in single message
<!-- SECTION:NOTES:END -->
