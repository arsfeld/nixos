# Battlestar Galactica Hostname Scheme

Proposed rename of all machines to BSG ship names.

| Current    | BSG name       | Why                                                                  |
| ---------- | -------------- | -------------------------------------------------------------------- |
| `storage`  | `galactica`    | Current flagship — media, databases, k3s server, backups             |
| ~~`cottage`~~ | **`pegasus`** | The old Galactica hardware — returned from retirement, still a battlestar (done) |
| `cloud`    | `basestar`     | Different architecture (aarch64 vs x86 = Cylon vs Colonial), remote, public-facing |
| `raider`   | `raider`       | Already a Cylon fighter — keep it, perfect for the gaming/dev rig    |
| `router`   | `colonialone`  | Civilian command ship — directs traffic, doesn't fight               |
| `r2s`      | `raptor`       | Small, nimble ARM recon/utility craft                                |
| `raspi3`   | `viper`        | Tiny fighter, one job                                                |
| `g14`      | `blackbird`    | Custom stealth ship — the portable/laptop outlier                    |
| `octopi`   | `demetrius`    | Small support vessel on a specialized mission (3D printing)          |

## Notes

Renaming touches:
- Tailscale node names (`*.bat-boa.ts.net`)
- sops recipients (`.sops.yaml`) and per-host secret files under `secrets/sops/`
- Colmena deployment targets
- DNS / cloudflared tunnel ingress for `*.arsfeld.one`
- Service registry (`modules/constellation/services.nix`)
- `hosts/<name>/` directory layout (auto-discovered by `flake-modules/hosts.nix`)
