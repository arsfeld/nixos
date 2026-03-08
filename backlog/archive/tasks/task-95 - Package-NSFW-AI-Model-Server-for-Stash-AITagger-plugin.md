---
id: task-95
title: Package NSFW AI Model Server for Stash AITagger plugin
status: In Progress
assignee:
  - claude
created_date: '2025-10-27 03:10'
updated_date: '2025-10-27 03:14'
labels:
  - enhancement
  - stash
  - ai
  - nixos-module
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The AITagger Stash plugin requires a separate AI model server to function. Currently, the plugin fails to connect because no AI server is running at http://localhost:8000.

Package the NSFW AI Model Server (https://github.com/skier233/nsfw_ai_model_server) as a NixOS service/module that can be declaratively configured and run on raider.

The server analyzes images and videos to automatically tag them with appropriate metadata. It uses PyTorch and various AI models for inference.

## Requirements

- Server must run on localhost:8000 (or be configurable)
- Must integrate with existing Stash configuration on raider
- Should support automatic model downloads or declarative model specification
- Must handle PyTorch dependencies properly in NixOS
- Should support GPU acceleration if available (NVIDIA/AMD/Intel)

## Installation Reference

- Installation instructions: https://github.com/skier233/nsfw_ai_model_server/wiki/Installation-Instructions-(Recommended)
- Repository: https://github.com/skier233/nsfw_ai_model_server
- Original approach uses Conda, needs adaptation to Nix

## Implementation Considerations

1. The server uses Conda for dependency management - this needs to be converted to Nix
2. Multiple requirements.txt files exist for different GPU types (NVIDIA, AMD, Intel, macOS)
3. Models need to be downloaded separately and placed in specific directories
4. May need patreon authentication for some models
5. Needs to start automatically with the system
6. Should coordinate with Stash service (both running on raider)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 NixOS module created for nsfw-ai-model-server service
- [ ] #2 Service runs and listens on configurable port (default: 8000)
- [ ] #3 PyTorch and AI model dependencies properly packaged
- [ ] #4 Models can be specified declaratively or downloaded automatically
- [ ] #5 Service starts automatically and integrates with systemd
- [ ] #6 AITagger plugin successfully connects to the server
- [ ] #7 Documentation added for configuration options
- [ ] #8 GPU acceleration supported (at least for NVIDIA)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Overview
Package the NSFW AI Model Server as a NixOS module that runs as a systemd service on raider, integrating with the existing Stash installation.

### Approach Decision

**Option A: Native Python Package (RECOMMENDED)**
- Create a proper Nix derivation for the server
- Package all Python dependencies including PyTorch
- Run as a systemd service similar to Stash
- Pro: Better integration with NixOS, easier to manage, consistent with Stash
- Pro: Can leverage existing Python packaging infrastructure
- Con: More complex initial setup, need to handle all dependencies

**Option B: Container-based**
- Use existing Docker images or build custom container
- Add to media.nix like other containerized services
- Pro: Easier initial setup, isolated environment
- Con: Less integrated with Stash, potential for permission/network issues

**Decision: Go with Option A (Native Package)** because:
1. Stash is already a native service, so this integrates better
2. Better resource efficiency (no container overhead)
3. Easier to share Python environment with Stash if needed
4. More consistent with NixOS declarative principles

### Implementation Stages

#### Stage 1: Package the Server Application
**Goal**: Create a Nix derivation for nsfw-ai-model-server
**Files to create**:
- `pkgs/nsfw-ai-model-server/default.nix` - Main package derivation

**Tasks**:
1. Fetch the source from GitHub (use fetchFromGitHub)
2. Create Python package with buildPythonApplication
3. Handle Python dependencies (PyTorch, FastAPI/Uvicorn, etc.)
4. Set up proper install phase to include lib/ and config/ directories
5. Create wrapper script that sets up paths correctly

**Key challenges**:
- PyTorch is large and needs CUDA support for GPU
- Multiple requirements.txt files for different platforms
- Need to identify all runtime dependencies

#### Stage 2: Create NixOS Module
**Goal**: Create a declarative configuration module for the service
**Files to create**:
- `modules/services/nsfw-ai-model-server.nix` - NixOS module

**Configuration options to expose**:
```nix
services.nsfw-ai-model-server = {
  enable = mkEnableOption "NSFW AI Model Server";
  port = mkOption { default = 8000; };
  host = mkOption { default = "127.0.0.1"; };
  modelsDir = mkOption { description = "Directory containing AI models"; };
  configDir = mkOption { description = "Directory for server configuration"; };
  enableCuda = mkOption { default = true; };
};
```

**Tasks**:
1. Define service options
2. Create systemd service unit
3. Set up proper user/group (potentially reuse stash user or create dedicated user)
4. Configure service dependencies and ordering
5. Set up proper environment variables for model paths

#### Stage 3: Model Management
**Goal**: Handle AI model downloads and configuration
**Files to modify**:
- `hosts/raider/configuration.nix` - Add model configuration

**Approach**:
- Models should be declaratively specified but downloaded separately
- Create a models directory under /var/lib/nsfw-ai-model-server/models
- Document how to download models (may need manual download due to Patreon auth)
- Consider using activation scripts for model setup

**Tasks**:
1. Set up models directory structure
2. Document model download process
3. Create helper script for model management (optional)
4. Ensure proper permissions on model files

#### Stage 4: Integration with Raider
**Goal**: Configure the service on raider host
**Files to modify**:
- `hosts/raider/configuration.nix` - Enable and configure service
- `flake.nix` - Add package to overlay if needed

**Tasks**:
1. Import the new module
2. Enable the service
3. Configure to listen on localhost:8000
4. Ensure it starts after required mounts
5. Add to stash service dependencies if needed

#### Stage 5: Testing and Documentation
**Goal**: Verify integration and document usage
**Tasks**:
1. Test server starts and responds to health checks
2. Test AITagger plugin can connect
3. Test inference with a sample image
4. Document configuration options in CLAUDE.md or inline comments
5. Add any necessary secrets to secrets.nix if needed

### Technical Considerations

**PyTorch Packaging**:
- Use nixpkgs' pytorch package with CUDA support
- For raider (NVIDIA GPU), use `python3Packages.pytorch-bin` with CUDA
- Dependencies will include: torch, torchvision, transformers, pillow, etc.

**Service Architecture**:
- Service runs as dedicated user (nsfw-ai-model-server)
- Socket activation NOT needed (always-running service)
- Logs via systemd journal
- Restart on failure

**Security**:
- Service binds to localhost only by default
- No external access (only Stash on same host)
- Models directory readable only by service user
- No secrets needed unless using Patreon models

### Dependencies

**NixOS packages needed**:
- python3
- python3Packages.pytorch-bin (CUDA variant)
- python3Packages.torchvision-bin
- python3Packages.fastapi
- python3Packages.uvicorn
- python3Packages.pillow
- python3Packages.numpy
- Additional ML libraries as discovered

**System requirements**:
- NVIDIA GPU (already present on raider)
- CUDA support (already configured)
- Sufficient disk space for models (~several GB)

### Success Criteria Mapping

1. ✓ Stage 1 & 2: NixOS module created
2. ✓ Stage 2: Service runs on configurable port
3. ✓ Stage 1: PyTorch dependencies packaged
4. ✓ Stage 3: Models specified declaratively
5. ✓ Stage 2: Service starts with systemd
6. ✓ Stage 5: AITagger connects successfully
7. ✓ Stage 5: Documentation complete
8. ✓ Stage 1 & 2: GPU acceleration configured
<!-- SECTION:PLAN:END -->
