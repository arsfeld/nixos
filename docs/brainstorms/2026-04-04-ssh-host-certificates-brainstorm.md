# Brainstorm: SSH Host Certificates

**Date:** 2026-04-04
**Status:** Complete
**Motivated by:** [jpmens.net — SSH Certificates: The Better SSH Experience](https://jpmens.net/2026/04/03/ssh-certificates-the-better-ssh-experience/)

## What We're Building

An SSH certificate authority that signs **host keys** for every Constellation host, so clients (primarily `arosenfeld@laptop`) trust all hosts via a single `@cert-authority` entry in `known_hosts` instead of TOFU-ing each host individually.

### Goals

- Kill TOFU prompts when first connecting to a new or reinstalled host
- Eliminate "REMOTE HOST IDENTIFICATION HAS CHANGED" warnings on host reinstalls (no more `ssh-keygen -R`)
- Keep the operation declarative — host certs get signed and deployed as part of the normal Colmena workflow
- Keep user-key management as-is (hardcoded keys in `modules/constellation/users.nix` stay)

### Explicitly Out of Scope

- **User certificates.** Current Nix-managed user keys are already a centralized trust model for a solo homelab. Adding user certs means short-lived-cert signing infrastructure that buys nothing here.
- **Replacing Tailscale identity.** Tailscale still handles network-layer auth. This is purely about SSH host identity.
- **Integrating cloudflared / `*.arsfeld.one` services.** Those don't use SSH.

## Why This Approach

### Chosen: Host certificates signed from a sops-encrypted CA, auto-applied at deploy time

- CA private key lives in sops (likely `secrets/sops/common.yaml`), decryptable only by the deploy agent (laptop).
- Every Constellation host gets a signed host certificate alongside its existing `ssh_host_ed25519_key`.
- NixOS config adds `services.openssh.extraConfig = "HostCertificate ..."` per host.
- Client side: the CA public key is committed to the repo and installed into `~/.ssh/known_hosts` (or `/etc/ssh/ssh_known_hosts`) as `@cert-authority *.bat-boa.ts.net ssh-ed25519 …`.

This fits the existing sops + Nix + Colmena workflow and requires no new services running on hosts.

### Alternatives considered

- **Full user + host certs.** Matches the blog post fully but adds signing infrastructure (short-lived cert issuance, `ssh-agent` integration, CA security). Overkill for a 1-user homelab.
- **Tailscale SSH.** Would remove SSH key/cert management entirely, but ties auth to Tailscale (lock-in) and is non-standard. Interesting future option.
- **Status quo.** Works today. The pain points are mild — this is a quality-of-life improvement, not a fix for something broken.

## Key Decisions

1. **Host certificates only** — no user certificates, no changes to user SSH keys.
2. **CA key stored in sops** — fits existing secret-management pattern, decryptable by deploy agent.
3. **Auto-sign at deploy** — signing is part of the Colmena workflow, zero manual steps per deploy.
4. **Apply to all Constellation hosts** — every host that enables `constellation.common` gets a host cert.
5. **CA pubkey distributed via repo** — it's public data, commit it and let clients pin via `@cert-authority`.

## Open Questions

These need answers at the plan stage, not the brainstorm stage:

1. **Signing location.** Does signing happen on the deploy machine (laptop pulls each host's pubkey, signs, pushes cert back) or on each host (CA key decrypted via sops-nix during activation)? The first keeps the CA key off hosts; the second is simpler but puts the CA key on every host — defeating the point of a CA.
2. **Host pubkey source.** Do we pre-generate host keys and store them in sops (deterministic, signable before first boot), or sign post-install by reading the auto-generated pubkey from the live host?
3. **Certificate TTL and rotation.** Long-lived (1-5 years) with manual rotation, or shorter (weeks/months) with deploy-time auto-renewal? Auto-renewal on every deploy makes TTL almost irrelevant.
4. **Principals on each cert.** Just `<host>.bat-boa.ts.net`? Also include LAN hostnames, IPs, mDNS `<host>.local`?
5. **Bootstrap path for brand-new hosts.** A freshly-installed host needs its first cert before you can benefit from cert-based trust. What's the first-connection flow?
6. **Client-side distribution.** Just the laptop `~/.ssh/known_hosts`, or also `/etc/ssh/ssh_known_hosts` on every host (so hosts trust each other)? The remote builder trust of `cloud.bat-boa.ts.net` in `common.nix:103-107` could then collapse into the CA trust.

## References

- [SSH Certificates: The Better SSH Experience (jpmens.net)](https://jpmens.net/2026/04/03/ssh-certificates-the-better-ssh-experience/) — source article
- Current SSH config: `modules/constellation/users.nix:43-55` (user keys), `modules/constellation/common.nix:103-107` (pinned host key)
- `ssh-keygen(1)` — `-s`, `-I`, `-n`, `-V` flags for certificate signing
- `sshd_config(5)` — `HostCertificate`, `TrustedUserCAKeys`
- `ssh_config(5)` — `@cert-authority` in `known_hosts`
