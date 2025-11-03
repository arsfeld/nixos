---
id: task-117
title: Investigate alternatives to ragenix for NixOS secret management
status: Done
assignee: []
created_date: '2025-10-31 18:21'
updated_date: '2025-10-31 19:06'
labels: []
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Research and evaluate modern secret management solutions as alternatives to the current ragenix setup. Current pain points include difficulty maintaining age files, complexity of editing secrets, and challenges with auditing. Need a solution with:
- Command line interface for easy decryption, editing, and auditing
- Excellent NixOS integration
- Better UX for managing complex secrets
- Doesn't need to be git-based
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document 3-5 viable alternatives with NixOS integration capabilities
- [x] #2 Compare each solution's workflow for creating, editing, and auditing secrets
- [x] #3 Evaluate integration approach with NixOS (modules, deployment, etc.)
- [x] #4 Assess migration complexity from current ragenix setup
- [x] #5 Provide recommendation with pros/cons for each option
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Research Approach

1. Investigate most popular NixOS-native secret management tools
2. Explore external secret manager integrations (Vault, 1Password, Bitwarden)
3. Compare workflows, features, and migration complexity
4. Provide structured recommendations

## Key Alternatives Identified

1. **sops-nix** - Most recommended community solution
2. **agenix** - Original age-based tool (ragenix is based on this)
3. **HashiCorp Vault** - Enterprise-grade external secret manager
4. **1Password/Bitwarden integrations** - Cloud-based secret managers
5. **password-store (pass)** - Traditional GPG-based approach
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Research Findings

### Current Pain Points Analysis
- ragenix uses age encryption with individual .age files
- Each secret is a separate encrypted file
- Editing requires ragenix CLI with --editor flag
- Auditing requires decrypting each file individually
- 88 secrets currently managed across multiple hosts
- Complexity increases with structured secrets (env files, JSON configs)

### Tools Researched

**sops-nix**
- Format: YAML/JSON/dotenv/INI/binary encrypted with age or PGP
- Integration: Native NixOS module, atomic provisioning
- Status: Most recommended in 2025, actively maintained by Mic92
- Key advantage: Multiple secrets in single file, structured format support

**agenix**
- Format: Individual .age files (like ragenix)
- Integration: NixOS module, Home Manager support
- Status: Original tool, simpler than sops-nix
- Key advantage: Simplicity, wide adoption

**HashiCorp Vault**
- Format: External server with API
- Integration: vault-secrets module (Serokell), vault-agent
- Status: Enterprise solution, requires separate infrastructure
- Key advantage: Centralized, auditing, dynamic secrets

**1Password (opnix)**
- Format: 1Password vaults with Service Account
- Integration: Pulls secrets at activation time
- Status: Modern integration, no SSH keys needed
- Key advantage: No git storage, ramfs-only runtime

**Bitwarden (sopswarden)**
- Format: Bitwarden vault synced to SOPS
- Integration: Hybrid approach with SOPS backend
- Status: Community project, less mature
- Key advantage: Cloud sync with local encryption

**password-store (pass)**
- Format: GPG-encrypted files in git
- Integration: NixOps integration, D-Bus service
- Status: Traditional Unix approach
- Key advantage: Standard tool, git-based

## LLM/Automation Friendliness Analysis

**Critical Requirement:** Must work well with Claude Code and other LLM tools (non-interactive, programmatic access)

### sops-nix
- **Set value:** `sops set file.yaml '["path"]["to"]["key"]' 'value'`
- **Get value:** `sops -d file.yaml | yq '.path.to.key'`
- **List all:** `sops -d file.yaml`
- **Pros:** Has programmatic access
- **Cons:** Complex JSON path syntax, requires additional tools for querying
- **LLM-friendly:** ⚠️ Moderate (awkward syntax)

### HashiCorp Vault
- **Set value:** `vault kv put secret/path key=value`
- **Get value:** `vault kv get -format=json secret/path | jq -r '.data.data.key'`
- **List all:** `vault kv list -format=json secret/`
- **Pros:** Dead simple CLI, excellent for automation, dev mode for testing
- **Cons:** Requires running server
- **LLM-friendly:** ✅ Excellent (simple, intuitive commands)

### 1Password (opnix)
- **Set value:** Requires JSON template or complex base64 piping
- **Get value:** `op item get item-name --fields password`
- **List all:** `op item list --format=json`
- **Pros:** Good GUI, cloud-based
- **Cons:** Complex automation for updates, requires subscription
- **LLM-friendly:** ⚠️ Moderate (get is easy, set is complex)

### Vault Dev Mode
- `vault server -dev` - Single command to start
- In-memory storage, auto-unsealed
- Perfect for local development and testing
- Can later deploy production Vault with persistent storage
- Available on port 127.0.0.1:8200

## Bitwarden Secrets Manager Deep Dive

**Official Product** (not the community sopswarden tool)

### Key Features
- Dedicated secrets management product (separate from password manager)
- Open source, end-to-end encrypted, zero-knowledge architecture
- Cloud-based (no infrastructure to maintain)
- Available in nixpkgs as `bws` package

### CLI Commands (bws)
```bash
# Authenticate
export BWS_ACCESS_TOKEN=your-token-here

# Create secret
bws secret create SECRET_NAME project-id org-id --note "Description"

# Get secret
bws secret get secret-uuid
bws secret get secret-uuid | jq -r '.value'

# List all secrets
bws secret list
bws secret list | jq

# Run command with secrets injected as env vars
bws run -- 'npm run start'
bws run -- 'echo $MY_SECRET'
```

### Pricing
- **Free tier**: Unlimited secrets, 2 users, 3 projects, 3 machine accounts
- **Teams**: $6/user/month, 20 machine accounts, unlimited projects
- **Enterprise**: $12/user/month, 50 machine accounts, self-hosting

### NixOS Integration
- Package available in nixpkgs: `bws`
- No official NixOS module yet
- Can use `bws run` to inject secrets into services
- Community tools: sopswarden (syncs to SOPS), sopsidy (pulls into sops-nix)

### LLM-Friendly Rating: ✅ Excellent
- Simple, intuitive CLI like Vault
- JSON output for easy parsing
- `bws run` command for easy integration
- Non-interactive commands for automation

### Pros vs Vault
- ✅ No infrastructure to maintain (cloud-based)
- ✅ Free tier available (perfect for personal use)
- ✅ Web UI included
- ✅ Already in nixpkgs
- ✅ Open source and auditable
- ✅ `bws run` command is elegant

### Cons vs Vault
- ⚠️ 3 machine accounts on free tier (might need Teams plan for multiple hosts)
- ⚠️ Less mature NixOS integration (no official module)
- ⚠️ Cloud dependency (requires internet)
- ⚠️ Uses project/org structure (more complex organization)
- ⚠️ Secrets referenced by UUID (less human-readable than Vault paths)

## Fly.io Self-Hosting Analysis

### HashiCorp Vault on Fly.io
- **Status**: ✅ Fully supported (no official guide, but possible)
- **Resources**: Fly.io uses Vault internally
- **Storage**: Use Fly.io volumes for persistence (3GB free)
- **Cost**: Free tier supports 3x256MB VMs + 3GB storage
- **Setup**: Docker container + fly.toml + volume mount
- **Advantages**: Full Vault features, self-hosted, low cost

### Vaultwarden on Fly.io
- **Status**: ✅ Excellent community support with guides
- **Resources**: Multiple GitHub repos with automated deployment
- **Cost**: <$5/month (or free on hobby tier)
- **BUT**: ❌ Does NOT support Secrets Manager (bws CLI)
- **Limitation**: Secrets Manager is proprietary Bitwarden feature
- **Use case**: Only for password management, not infrastructure secrets

### Bitwarden Official Server
- **Status**: ⚠️ Requires Enterprise tier ($12/user/month)
- **Self-hosting**: Available but defeats the purpose of 'free'
- **Conclusion**: Not a cost-effective self-hosting option

### Recommendation for Fly.io
**Deploy HashiCorp Vault on Fly.io** is the best self-hosted option:
- Free tier is sufficient for small deployments
- Full Vault features (Secrets Manager equivalent)
- No proprietary limitations
- Community examples exist (though not official Vault guides)

## CORRECTION: Fly.io Hosting Reality

**HashiCorp Vault on Fly.io**: ❌ NOT RECOMMENDED
- Unsealing complexity (requires manual intervention after restarts)
- HA/clustering difficult with Fly.io's model
- Storage persistence concerns
- No official guide, community struggles
- "Prod deployment guide looks rather daunting and I haven't seen any mentions of anyone setting it up successfully here" - Fly.io community

**Vaultwarden on Fly.io**: ❌ Doesn't support Secrets Manager
- Only works as password manager, not infrastructure secrets
- bws CLI incompatible (proprietary feature)

**Conclusion**: Fly.io is NOT a good platform for self-hosted secret management

## Final Recommendations (Corrected)

### 🥇 Best Overall: Vault on Storage Host
**Why**: You already manage infrastructure, most control, excellent CLI
- Setup: 1-2 hours
- Cost: Free
- Access: Via Tailscale (already configured)
- Migration: Straightforward script
- NixOS: Official module + vault-secrets integration

### 🥈 Best for Zero Maintenance: Bitwarden Secrets Manager
**Why**: Cloud-hosted, excellent CLI, $6/mo is cheap for convenience
- Setup: 5 minutes
- Cost: $6/month (Teams tier for 20 machine accounts)
- Access: From anywhere
- Migration: Simple script
- NixOS: Custom integration via bws CLI

### 🥉 Best for Git Workflow: sops-nix
**Why**: Most popular NixOS solution, but less LLM-friendly
- Setup: 2-4 hours
- Cost: Free
- Access: Git-based
- Migration: Moderate complexity
- NixOS: Official module, well-maintained

## Migration Complexity Assessment

### To Vault (Storage Host)
**Effort**: 2-3 hours
**Steps**:
1. Deploy Vault on storage (30 min)
2. Initialize and configure (30 min)
3. Write migration script (30 min)
4. Migrate secrets (30 min)
5. Update service configs (30 min)

### To Bitwarden Secrets Manager
**Effort**: 1-2 hours
**Steps**:
1. Create account and organization (10 min)
2. Create projects and machine accounts (20 min)
3. Write migration script (20 min)
4. Migrate secrets (20 min)
5. Update service configs (30 min)

### To sops-nix
**Effort**: 3-4 hours
**Steps**:
1. Add sops-nix to flake (10 min)
2. Configure .sops.yaml (20 min)
3. Consolidate 88 secrets into YAML files (60 min)
4. Update all service configs (90 min)
5. Test on each host (30 min)

## Infisical Analysis - Strong Contender!

### Overview
- Open source (MIT license) secrets management platform
- 16K+ GitHub stars, Y Combinator backed
- 3 years old vs Vault's 11 years (younger but modern)
- Focus: Developer experience and ease of use

### CLI Commands (infisical)
```bash
# List all secrets
infisical secrets

# Get specific secrets
infisical secrets get SECRET_NAME
infisical secrets get NAME1 NAME2 --plain

# Set secrets
infisical secrets set KEY=value KEY2=value2
infisical secrets set DATABASE_URL=postgres://...

# Delete secrets
infisical secrets delete KEY1 KEY2

# Inject secrets into commands
infisical run -- npm start
infisical run -- docker compose up
```

### Self-Hosting
- ✅ Docker Compose ready (official docker-compose.prod.yml)
- ✅ Simple setup: PostgreSQL + Redis + Infisical backend
- ✅ Can run on storage host easily
- ✅ Web dashboard included
- ✅ One command deploy: `docker-compose -f docker-compose.prod.yml up`

### NixOS Integration
- ✅ CLI available in nixpkgs: `infisical`
- ❌ No official NixOS module for self-hosted server (yet)
- ✅ Can use Podman/Docker for server deployment
- ✅ CLI works perfectly with NixOS

### LLM-Friendly Rating: ✅ Excellent
- Simple, intuitive commands like Vault
- Less verbose than sops-nix
- `infisical run` for easy injection
- JSON output support

### Key Advantages over Vault
1. **Much easier setup** - Docker Compose vs complex Vault config
2. **Better UX** - Built-in project/environment separation
3. **Modern dashboard** - Compare secrets across environments easily
4. **100+ integrations** - GitHub, AWS, Vercel, etc.
5. **Developer-first** - Language/platform agnostic CLI
6. **True open source** - MIT license (Vault is BSL)
7. **Personal overrides** - For local development
8. **Secret sharing** - Built-in secure sharing

### Advantages over Bitwarden SM
1. **Self-hostable** - No cloud dependency
2. **Free forever** - No machine account limits
3. **Better automation** - Designed for infra secrets
4. **More features** - PKI, dynamic secrets, etc.

### Pricing
- Self-hosted: $0 (free forever)
- Cloud: $9/month (cheaper than Bitwarden $6/month)

### Potential Concerns
- Younger project (3 years vs Vault 11 years)
- Requires Docker/Podman (but you already use this)
- No official NixOS module (but CLI works great)

## High Availability & Failure Analysis

### Current ragenix Setup
**Failure mode**: ✅ Resilient
- Secrets encrypted in git repo
- Each host has local copy after deployment
- Storage down = existing services continue working
- Can still deploy from any machine with git access

### Centralized Solutions (Vault/Infisical on storage)
**Failure mode**: ⚠️ Single point of failure
- Storage down = can't fetch secrets
- Existing services keep running (already have secrets)
- **Cannot deploy new services**
- **Cannot restart services that fetch secrets at startup**
- **Cannot make secret changes**

### Mitigation Strategies

**Option 1: Secrets fetched at build/activation time**
- NixOS fetches secrets during `nixos-rebuild`
- Secrets stored in /run/secrets (local tmpfs)
- Storage down = existing deployments work, new deployments fail
- Best for: Infrequent deployments

**Option 2: vault-agent / local caching**
- Agent caches secrets locally on each host
- Auto-renews from Vault/Infisical when available
- Falls back to cache if storage down
- Best for: Frequent secret access, HA requirements

**Option 3: Multi-host HA**
- Run Vault/Infisical on both storage AND cloud
- Replicate secrets between hosts
- Either can serve secrets
- Best for: Critical production workloads

**Option 4: Hybrid approach**
- Use sops-nix for secret storage (git-based, distributed)
- Use Infisical/Vault as management interface
- Secrets committed to git after changes
- Best for: Getting both UX and resilience

### Cloud-Based Solutions (Bitwarden SM, Infisical Cloud)
**Failure mode**: ⚠️ Internet dependency
- Cloud down or no internet = can't fetch secrets
- More reliable than single host (cloud SLA)
- But introduces external dependency

## Final Summary

### Top 3 Recommendations:

**1. sops-nix** - Best balance of UX improvement + resilience
- Solves multi-secret editing pain point
- Git-based (no SPOF)
- Most popular NixOS solution
- Good enough LLM CLI
- Migration: 3-4 hours

**2. Infisical (self-hosted on storage)** - Best UX if SPOF acceptable
- Easiest setup (docker-compose)
- Best CLI and web UI
- MIT licensed, modern
- Accept: Single point of failure
- Migration: 2-3 hours

**3. Bitwarden Secrets Manager Cloud** - Best for zero maintenance
- No infrastructure
- Cloud reliability
- $6/month for 20 machine accounts
- Accept: External dependency
- Migration: 1-2 hours

### Key Findings:
- Vault/Infisical on single host = SPOF (can't deploy if storage down)
- sops-nix keeps ragenix's resilience while improving UX
- Hybrid approaches possible (Infisical for management + git for storage)
- All options have excellent LLM-friendly CLIs except sops (moderate)

### Decision Factors:
- **Resilience priority** → sops-nix
- **Best UX priority** → Infisical (accept SPOF)
- **Zero maintenance** → Bitwarden SM Cloud
- **Enterprise features** → Vault on storage
<!-- SECTION:NOTES:END -->
