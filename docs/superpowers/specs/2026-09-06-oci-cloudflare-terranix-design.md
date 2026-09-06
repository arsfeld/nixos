# Managing basestar's Oracle Cloud infrastructure as code

**Date:** 2026-09-06
**Status:** Approved, ready for planning

## Problem

basestar runs on an Oracle Cloud VM. Every change to the infrastructure *around*
the machine — ingress rules, volume size, the public IP, anything net-new —
requires loading the OCI console. There is no record in this repo of what the
tenancy contains, so the layout lives only in Oracle's database and in memory.

The same is true one layer up: the Cloudflare DNS records that point at basestar
and galactica are edited by hand in a second web console. `CLAUDE.md` already
documents one of these records as load-bearing and easy to get wrong — the
grey-cloud (DNS-only) A record for `niks3.arsfeld.dev`, which must not be
proxied or GitHub-hosted runners get a managed challenge.

## Goal

Describe the Oracle tenancy and the in-use Cloudflare DNS zones as code in this
repository, adopting what already exists without recreating any of it, and make
routine changes a `just` invocation rather than a console session.

## Non-goals

- The five parked Cloudflare zones (`arsfeld.net`, `arsfeld.xyz`, `finaro.io`,
  `mydia.dev`, `whatsrev.app`).
- R2 buckets, the `cache.arsfeld.dev` custom domain, and the rest of the
  Cloudflare account beyond DNS.
- The cloudflared tunnel itself.
- Any CI integration. Apply stays a deliberate local act.
- Creating new infrastructure. This change imports; it does not provision.

## Approach

OpenTofu, with the configuration written in Nix via **terranix** rather than
HCL. This was a deliberate choice over plain HCL: the repository is already
entirely Nix, formatted by alejandra and evaluated through flake-parts, and
infrastructure written in the same language stays consistent with it.

The cost is paid once, during adoption: OCI resource discovery and
`tofu plan -generate-config-out` both emit HCL, which has to be hand-translated
into terranix modules. After that the codegen layer is invisible.

Every component is already packaged in the repository's pinned nixpkgs:

| Component | Version |
|---|---|
| `opentofu` | 1.11.8 |
| `terraform-providers.oracle_oci` | 8.14.0 |
| `terraform-providers.cloudflare_cloudflare` | 5.19.1 |
| `oci-cli` | 3.82.0 |

The OpenTofu on `$PATH` today is 1.12.5, but that comes from nixpkgs-unstable
via `constellation.development`. The pinned nixpkgs this flake builds against
has 1.11.8, which is what the wrapped binary will be. Both feature floors this
design needs sit below it: `import` blocks landed in 1.5, S3-native state
locking (`use_lockfile`) in 1.10.

## Layout

```
infra/
  default.nix          # terranix entry — imports everything below
  terraform.nix        # required_providers + R2 state backend
  providers.nix        # oci + cloudflare provider config, fed from TF_VAR_*
  variables.nix        # credential variable declarations
  oci/
    network.nix        # VCN, internet gateway, route table, security list, subnet
    basestar.nix       # instance, boot volume, VNIC, public IP
  dns/
    arsfeld-dev.nix    # 23 records
    arsfeld-one.nix    # 7 records
    rosenfeld-one.nix  # 20 records
flake-modules/infra.nix  # terranix flake-parts module → packages.infra-config
secrets/sops/infra.yaml  # credentials, recipient: user key only
```

`infra/` sits at the repository root and deliberately **not** under `modules/`.
Haumea auto-loads that tree as NixOS modules; terranix modules there would fail
to evaluate for every host.

## Components

### terranix evaluation (`flake-modules/infra.nix`)

Adds `terranix` as a flake input following the repository's nixpkgs, and exposes
`packages.infra-config` — a derivation containing the generated
`config.tf.json`. OpenTofu reads `.tf.json` natively, so no HCL is ever written
to disk by hand.

`flake.nix` imports the new module explicitly, alongside the six existing ones.

### Provider pinning (dev shell)

`flake-modules/dev.nix` gains:

- `opentofu.withPlugins (p: [p.oracle_oci p.cloudflare_cloudflare])`
- `oci-cli`, for discovery and ad-hoc inspection

The wrapper installs both providers into a local plugin mirror, so `tofu init`
never contacts the registry and provider versions advance with `flake.lock`.
This mirrors the guarantee the nixpkgs pin already provides everywhere else in
the repository.

### Credentials (`secrets/sops/infra.yaml`)

A new sops file whose only recipient is `user_arosenfeld`. No host needs these
credentials — the run model is local — and narrowing the recipient list follows
the precedent already set by `ntfy-client.yaml`.

Key names are not free choices. OpenTofu reads `TF_VAR_<name>` for a variable
called `<name>`, and the OCI resource-discovery tool reads a **fixed** set of
`TF_VAR_` names for its own authentication — `TF_VAR_tenancy_ocid`,
`TF_VAR_user_ocid`, `TF_VAR_fingerprint`, `TF_VAR_region`,
`TF_VAR_private_key_path`. Naming the terranix variables to match means one set
of environment variables serves both the provider and discovery, with no
translation layer:

| Key | Purpose |
|---|---|
| `TF_VAR_tenancy_ocid` | OCI tenancy |
| `TF_VAR_user_ocid` | OCI user the API key belongs to |
| `TF_VAR_fingerprint` | API key fingerprint |
| `TF_VAR_region` | Home region |
| `OCI_PRIVATE_KEY_B64` | API private key, base64-encoded |
| `TF_VAR_cloudflare_api_token` | Scoped token, Zone:DNS:Edit on three zones |
| `AWS_ACCESS_KEY_ID` | R2 token for the state bucket |
| `AWS_SECRET_ACCESS_KEY` | R2 token for the state bucket |

The two `AWS_*` names are fixed by the S3 backend, which reads credentials from
the environment rather than from variables.

The private key is the one value that cannot travel as an environment variable:
a PEM contains newlines, and the dotenv format sops emits is line-oriented. It
is stored base64-encoded and the `just tf` recipe decodes it to a mode-0600
temporary file, exporting `TF_VAR_private_key_path` to point at it and removing
it on exit. Both the provider (`private_key_path = var.private_key_path`) and
resource discovery consume it that way, so the two paths stay identical.

The Cloudflare credential is a **new scoped token**, not the global API key that
already sits in `common.yaml`. The global key carries every permission on the
account; a token scoped to DNS edit on three zones is the correct blast radius
for a tool that runs `apply`.

The file is created non-interactively: a plaintext YAML is written to a path
outside the repository, encrypted in place with `sops -e`, and the source
removed. No editor session.

### State backend

A new R2 bucket, `tfstate`, addressed through OpenTofu's S3 backend:

```
bucket        = "tfstate"
key           = "nixos-infra.tfstate"
region        = "auto"
endpoints.s3  = "https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com"
use_path_style              = true
use_lockfile                = true
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_s3_checksum            = true
```

The account ID is already committed in `hosts/basestar/services/niks3.nix`, so
writing it here adds no exposure. `use_lockfile` gives S3-native locking via
conditional PUT, which R2 supports; no DynamoDB substitute is required.

**No lifecycle rule on this bucket**, for the same reason `CLAUDE.md` forbids one
on `nix-cache`, and one more besides: object versioning is the only undo
available for a corrupted state file.

## Adoption

Nothing is created. Every resource is imported, in order:

1. **Discover.** Run the OCI provider binary's resource-discovery mode
   (`terraform-provider-oci -command=export -compartment_id=…`) into a scratch
   directory outside the repository. It emits HCL and the OCIDs for everything
   that exists.
2. **Translate.** Hand-write the terranix modules using that output as the
   reference. Roughly a dozen OCI resources; the 50 DNS records come from the
   Cloudflare API rather than from discovery.
3. **Adopt.** Use OpenTofu `import` blocks, so `tofu plan` displays the adoption
   before state is touched. terranix supports these natively — `import` is one
   of the top-level keys its serializer emits, taking a list of `{to, id}`
   attribute sets — so no workaround or custom module option is needed. Verified
   against terranix 2.9.0.
4. **Converge.** Iterate until `tofu plan` reports no changes.

### Acceptance criterion

**An empty plan.** `tofu plan` producing zero additions, zero changes and zero
destructions is what proves the Nix describes the infrastructure that exists
rather than something adjacent to it. Nothing short of that counts as done.

## Day-to-day workflow

A single passthrough recipe in the justfile:

```
just tf plan
just tf apply
just tf state list
```

`just tf <args>` rebuilds `config.tf.json` from Nix, places it in a gitignored
working directory, and runs `tofu <args>` under `sops exec-env`. It runs
`tofu init` automatically when `.terraform` is absent, so first use needs no
separate step.

## Safety

Three rails, all of them structural rather than procedural:

- **`lifecycle.prevent_destroy = true`** on the instance, boot volume, public IP
  and VCN. A plan that would delete basestar fails to generate rather than
  failing to apply.
- **`lifecycle.ignore_changes` on the instance's `source_details`.** basestar was
  installed onto a stock Oracle image. When Oracle deprecates that image OCID,
  an unguarded configuration would propose replacing the machine.
- **No dedicated destroy recipe.** `just tf destroy` still reaches it through the
  passthrough, so the capability is not removed — but it has to be typed in full
  and read on the way past, rather than sitting in `just --list` next to `plan`.

### DNS drift

Nothing in this repository writes Cloudflare records — verified by search — so
there is no automation for OpenTofu to fight, and no source of perpetual drift.

The one live hazard is adding a tunnel public hostname through the Zero Trust
dashboard: that creates a CNAME outside OpenTofu's knowledge, and the next apply
would delete it. galactica's wildcard ingress means this should not arise in
practice, but it is the failure mode to recognise.

## Manual prerequisites

One console session, once:

1. **OCI:** create an API signing key for the user; record the tenancy OCID,
   user OCID, fingerprint and region from the configuration-file preview, and
   download the private key.
2. **Cloudflare:** create an API token scoped to Zone:DNS:Edit on `arsfeld.dev`,
   `arsfeld.one` and `rosenfeld.one`.
3. **Cloudflare R2:** create the `tfstate` bucket and an R2 API token scoped to
   it.

## Open question

`168.138.71.109` may be an *ephemeral* public IP, which Oracle reassigns if the
instance is ever stopped and started. It is load-bearing: `CLAUDE.md` documents
it as the grey-cloud A record target for `niks3.arsfeld.dev`, and the deploy
pipeline's push path depends on it resolving.

Discovery will establish which it is. If it is ephemeral, converting it to a
reserved public IP is a small and genuinely valuable change — but it is a
mutation rather than an import, and therefore outside this change's scope. It
gets reported, not performed.

## Zones and record counts

| Zone | Zone ID | Records |
|---|---|---|
| `arsfeld.dev` | `5b658a2265b2562c6f51ac93de8d21bf` | 23 |
| `arsfeld.one` | `877dc2cb2972842c423b9c9851d95cc7` | 7 |
| `rosenfeld.one` | `1c77692238095c6a5a263ab71c301ed8` | 20 |
