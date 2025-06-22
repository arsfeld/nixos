# Supabase Dynamic Management - TODO

## Phase 1: Foundation Setup

### 1. Create NixOS Module for Dynamic Supabase
- [x] Create `/modules/supabase.nix` with:
  - [x] Docker and docker-compose enablement
  - [x] Directory structure creation via systemd.tmpfiles
  - [x] Caddy configuration with dynamic imports
  - [x] Python and uv installation
  - [x] User and permissions setup

### 2. Create Base Python Script Structure
- [x] Create `/modules/supabase/supabase-manager.py`
- [x] Add uv script header with dependencies
- [x] Implement basic Textual app structure
- [x] Create main dashboard view skeleton
- [x] Add CLI argument parsing for direct commands

### 2.1. Remove Old Supabase Module
- [x] Remove entire `/modules/supabase/` directory (old static module)
- [x] Remove old scripts and configuration files
- [x] Update cloud host configuration to use new `services.supabase`
- [x] Clean up arsfeld-dev site configuration
- [x] Remove old secret files and references
- [x] Format all files with alejandra

### 3. Implement Core Functions
- [x] Create `download_supabase_files()` function:
  - [x] Download docker-compose.yml from GitHub
  - [x] Download kong.yml configuration
  - [x] Download all volume initialization scripts
  - [x] Cache downloaded files with version tracking
- [x] Create `generate_secrets()` function:
  - [x] Generate JWT secret (32 bytes)
  - [x] Generate anon and service role keys
  - [x] Generate database passwords
  - [x] Generate dashboard passwords
- [x] Create `render_docker_compose()` function:
  - [x] Template docker-compose.yml with instance values
  - [x] Set unique container names
  - [x] Configure port mappings
  - [x] Set environment variables

## Phase 2: Instance Management

### 4. Implement Instance CRUD Operations
- [x] Create `create_instance()` function:
  - [x] Validate instance name
  - [x] Create instance directory
  - [x] Generate all secrets
  - [x] Render configuration files
  - [x] Create Caddy configuration
  - [x] Add to state.json
  - [x] Start containers
- [x] Create `delete_instance()` function:
  - [x] Stop all containers
  - [x] Remove containers and volumes
  - [x] Delete instance directory
  - [x] Remove Caddy configuration
  - [x] Update state.json
- [x] Create `start_instance()` and `stop_instance()`
- [x] Create `list_instances()` with status check
- [x] Add CLI commands for all operations
- [x] Implement start-all and stop-all for systemd

### 5. Implement State Management
- [x] Design state.json schema:
  ```json
  {
    "instances": {
      "project1": {
        "created_at": "2025-01-15T10:30:00Z",
        "ports": {
          "kong": 8000,
          "studio": 3000,
          "inbucket": 54324
        },
        "version": "latest",
        "status": "running"
      }
    }
  }
  ```
- [x] Create state read/write functions with locking
- [x] Implement state recovery on corruption

### 6. Implement Caddy Integration
- [x] Create Caddy template for each instance:
  - [x] API endpoint (project.arsfeld.dev)
  - [x] Studio endpoint (project-studio.arsfeld.dev)
  - [x] Mail endpoint (project-mail.arsfeld.dev)
- [x] Implement Caddy reload trigger
- [x] Add health check endpoints

## Phase 3: Terminal UI

### 7. Build Main Dashboard
- [ ] Create instance list widget
- [ ] Add status indicators (running/stopped)
- [ ] Show resource usage (CPU/Memory)
- [ ] Implement keyboard navigation
- [ ] Add create instance button
- [ ] Add refresh functionality

### 8. Build Instance Detail View
- [ ] Show instance metadata
- [ ] List all containers with status
- [ ] Display URLs and endpoints
- [ ] Show environment variables (masked secrets)
- [ ] Add action buttons (start/stop/restart/delete)
- [ ] Create logs viewer widget

### 9. Build Create Instance Wizard
- [ ] Name input with validation
- [ ] Advanced options screen:
  - [ ] Custom port selection
  - [ ] Resource limits
  - [ ] Version selection
- [ ] Secret preview screen
- [ ] Confirmation screen
- [ ] Progress indicator during creation

### 10. Build Monitoring View
- [ ] Real-time resource usage graphs
- [ ] Container health status
- [ ] Recent logs aggregator
- [ ] Error highlighting

## Phase 4: Container Management

### 11. Implement Docker Integration
- [ ] Use Docker SDK for Python
- [ ] Create container management functions:
  - [ ] List containers by instance
  - [ ] Get container stats
  - [ ] Stream container logs
  - [ ] Execute commands in containers
- [ ] Implement health checks
- [ ] Add restart policies

### 12. Port Management
- [ ] Create port allocation system
- [ ] Track used ports in state.json
- [ ] Implement port conflict detection
- [ ] Allow custom port specification

## Phase 5: Testing & Deployment

### 13. Add to Cloud Host
- [x] Enable module in `/hosts/cloud/configuration.nix`
- [x] Deploy module successfully (no build errors)
- [ ] Verify Caddy integration works
- [ ] Test instance creation and deletion

### 14. Create Test Instance
- [ ] Fix Docker Compose template formatting (Python string format syntax)
- [ ] Use CLI to create "test" instance
- [ ] Verify all services start correctly
- [ ] Test API endpoint
- [ ] Access Studio interface
- [ ] Check Inbucket mail interface

### 15. Documentation & Cleanup
- [ ] Update main documentation
- [ ] Add troubleshooting guide
- [x] Remove old Supabase modules
- [x] Clean up unused secrets

## Current Status

### ✅ **Progress Made**
- NixOS module deployed successfully to cloud host (no build errors)
- Service starts without crashing  
- Package system working with uv dependencies  
- Downloaded Supabase templates successfully
- Basic CLI commands (list, download) working

### 🔧 **Current Issues**
- **Docker Compose Template Bug**: Used `${{variable}}` syntax instead of `{variable}` for Python string formatting
- Instance creation fails at template rendering step
- **No verification yet**: Caddy integration, actual instance creation, web interfaces

### 🎯 **Next Steps**
1. Fix string formatting in Docker Compose template  
2. Complete test instance creation
3. Verify all Supabase services start correctly
4. Test web interfaces (API, Studio, Mail)
5. Build TUI dashboard for better user experience

## Specific First Steps

1. **Start with the NixOS module** - This gives us the foundation
2. **Create minimal Python script** - Just CLI structure and basic TUI
3. **Implement create_instance** - Core functionality first
4. **Add dashboard view** - Visual feedback
5. **Test on cloud host** - Verify it works in real environment

## Technical Notes

- Use port range 8000-8999 for Kong (API)
- Use port range 3000-3999 for Studio
- Use port range 54300-54399 for Inbucket
- Instance names must be alphanumeric + hyphens
- All secrets should be 32+ characters
- Container names: `supabase-{instance}-{service}`
- Networks: `supabase-{instance}`