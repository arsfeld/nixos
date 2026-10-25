# Container hardening — design

Date: 2026-10-25. Prompted by CVE-2026-111497 (see
`2026-10-24-brotli-cve-2026-111497-design.md`), but general: it applies to
every `media.services` container, whatever it runs.

## Why containment, not a fix

No language-agnostic setting stops a decoder bug from being triggered. Node and
.NET bundle their own Brotli, so replacing or preloading the system library
misses them. The only universal block, a TLS-intercepting egress proxy that
strips `br` from requests, needs a private CA trusted by every runtime's own
store (Node, .NET, certifi, Go) and was rejected as too fragile. What does work
everywhere is limiting what a compromised container can do.

What this buys: no privilege gain inside a container (setuid binaries, file
capabilities), and far fewer kernel interfaces for escaping to the host.

What it does not buy: an app's own data, secrets and network reach are the
attacker's once the app is compromised. Containers with a known exploitable
decoder stay disabled regardless (galactica's hermes, ask, radarr, sonarr,
jackett, `1fcac3d8`).

## Options — `modules/media/containers.nix`

```nix
media.containers.<name>.hardening = {
  enable = true;            # default for every container
  caps = <profile default>; # added back after --cap-drop=ALL
};
```

When `enable` is true, the lowering into `virtualisation.oci-containers`
appends:

- `--cap-drop=ALL`
- `--cap-add=<cap>` for each entry in `caps`
- `--security-opt=no-new-privileges`

Default `caps` is chosen from the image:

- linuxserver images (`ghcr.io/linuxserver/*`, `lscr.io/linuxserver/*`) start
  as root under s6 and drop to the media user: `CHOWN DAC_OVERRIDE FOWNER
  SETUID SETGID KILL`.
- every other image: `[]`.

A container that needs more sets `caps` explicitly, with a comment saying
why. Capabilities currently granted through `extraOptions`
(`--cap-add=NET_ADMIN` on pegasus's transmission) move into `caps`.

`privileged = true` skips hardening automatically; it overrides capabilities
anyway.

Opting out is `hardening.enable = false` with a comment giving the reason.
`media.services.<name>.container` is a free-form attrset merged into
`media.containers.<name>`, so `container.hardening` passes through with no
change to `modules/media/services.nix`.

Podman's own defaults already exclude `SYS_ADMIN`, `NET_RAW` and `SYS_PTRACE`,
so a single shared add-back list would remove only 5 of the 11 default
capabilities. The value is in the per-image fit: most non-linuxserver images
run as an ordinary user and need none.

## Out of scope

- Containers written directly to `virtualisation.oci-containers`: basestar's
  planka, siyuan and iroh-relay; galactica's isponsorblock and vpn-exit-nodes
  (both disabled). The tsnsrv sidecars written by `modules/tsnsrv.nix`.
- k3s pods on basestar.
- User namespaces, network isolation (including the per-database `trust` rules
  for the whole podman subnet in `pg_hba`), and a recurring vulnerable-image
  scan. Each is a possible follow-up spec.

## Rollout

Hosts in waves: pegasus, then basestar, then galactica. No host's wave is
deployed until its pre-flight passes.

### Pre-flight probe

A throwaway script, not committed. For every container the new configuration
declares on the host, it runs the image twice with no volumes, ports or
environment files, under a `capprobe-` name:

1. a control run with podman's default flags;
2. a hardened run with the flags the new configuration generates.

After 45 seconds it records, for each run, whether the container is still up,
its exit code, and log lines matching `Operation not permitted`, `EPERM` or
`permission denied`. Only a container whose control run survives and whose
hardened run fails or logs those errors is a hardening failure; an image that
dies without its config either way tells us nothing and is checked after the
deploy instead. Each failure gets a `caps` entry, re-probed until it passes,
or an opt-out.

### Per-wave deploy and checks

1. `just deploy <host>`.
2. `systemctl --failed` is empty, and the set of running containers matches
   the set before the deploy.
3. For every container, `podman inspect` shows `EffectiveCaps` equal to its
   configured `caps` and `no-new-privileges` in `SecurityOpt`.
4. Every hardened container's published port on `127.0.0.1` answers with
   something other than a 5xx or a connection failure. This tests the
   container itself rather than the gateway in front of it.
5. Any failure: give the container its `caps` or opt it out, redeploy, and
   re-check before the next host.

## Error handling

- A container that cannot start hardened fails its unit, which is visible in
  `systemctl --failed` and in step 2; the fix is per container and local.
- Rolling back a whole wave is redeploying the previous commit.
