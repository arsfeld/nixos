---
id: task-55
title: Add justfile task for building octopi SD card image
status: Done
assignee: []
created_date: '2025-10-16 23:00'
updated_date: '2025-10-16 23:01'
labels:
  - nixos
  - tooling
dependencies: []
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add a justfile recipe to simplify building the octopi SD card image.

**Requirements:**
- Add a recipe to justfile for building the octopi SD card image
- Recipe should run `nix build .#octopi`
- Should be consistent with existing justfile patterns
- Test the recipe to ensure it works

**Usage:**
```bash
just build-octopi
```
or similar naming convention
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 justfile recipe added for building octopi image
- [x] #2 Recipe successfully builds the SD card image
- [x] #3 Recipe follows existing justfile conventions
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

**Added justfile recipe:**

Created `build-octopi` recipe in justfile that:
1. Runs `nix build .#octopi -L` to build the SD card image
2. Shows helpful output with flashing instructions
3. Follows existing justfile patterns (similar to `build-kexec`)
4. Provides two flashing methods (direct pipe and two-step)

**Usage:**
```bash
just build-octopi
```

**Location in justfile:**
Added after `router-test` and before `build-kexec` (lines 174-194)

**Recipe features:**
- Uses `-L` flag for live build output
- Shows clear success message
- Provides SD card flashing instructions
- Follows justfile bash script conventions with proper error handling
<!-- SECTION:NOTES:END -->
