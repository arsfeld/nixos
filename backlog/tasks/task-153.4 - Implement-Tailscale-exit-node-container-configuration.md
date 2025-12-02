---
id: task-153.4
title: Implement Tailscale exit node container configuration
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 19:56'
labels:
  - implementation
  - containers
  - tailscale
dependencies:
  - task-153.3
parent_task_id: task-153
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the Tailscale container that runs in gluetun's network namespace and advertises as an exit node.

## Tailscale Container Requirements

```nix
virtualisation.oci-containers.containers."tailscale-${name}" = {
  image = "tailscale/tailscale:latest";
  
  dependsOn = [ "gluetun-${name}" ];
  
  environment = {
    TS_AUTHKEY = "file:/run/secrets/ts-authkey";
    TS_HOSTNAME = cfg.tailscaleHostname; # e.g., "brazil-exit"
    TS_EXTRA_ARGS = "--advertise-exit-node --accept-dns=false";
    TS_STATE_DIR = "/var/lib/tailscale";
    TS_USERSPACE = "false"; # Use kernel mode for better performance
  };
  
  volumes = [
    "tailscale-${name}-state:/var/lib/tailscale"
    "${cfg.secrets.tailscaleAuthKey}:/run/secrets/ts-authkey:ro"
  ];
  
  extraOptions = [
    # Use gluetun's network namespace
    "--network=container:gluetun-${name}"
  ];
};
```

## Key Considerations

1. **Network namespace** - Must use `--network=container:gluetun-xxx`
2. **State persistence** - Named volume for Tailscale state
3. **Auth key** - File-based auth key injection
4. **Exit node flags** - `--advertise-exit-node` is critical
5. **DNS** - `--accept-dns=false` since gluetun handles DNS
6. **Startup order** - Wait for gluetun to be healthy

## Tailscale Admin Console

After deployment:
1. Exit node appears in admin console
2. Must approve exit node in admin (or use auto-approve in ACLs)
3. Clients can then select the exit node
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Tailscale container uses gluetun's network namespace
- [x] #2 Container authenticates with Tailscale using auth key
- [x] #3 Exit node advertised with correct hostname
- [x] #4 State persisted across container restarts
- [ ] #5 Exit node visible in Tailscale admin console
<!-- AC:END -->
