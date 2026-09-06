# OCI + Cloudflare DNS as code (terranix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Oracle Cloud tenancy behind basestar and the three in-use Cloudflare DNS zones under OpenTofu, written in Nix via terranix, importing everything that already exists and creating nothing.

**Architecture:** A `terranix` flake input evaluates Nix modules under `infra/` into a `config.tf.json` derivation. A `just tf` recipe links that into a gitignored working directory, loads credentials from a new sops file, and runs an OpenTofu binary wrapped with both providers from nixpkgs. Adoption happens through OpenTofu `import` blocks, which terranix emits natively.

**Tech Stack:** terranix 2.9.0, OpenTofu 1.11.8 (pinned nixpkgs), `terraform-providers.oracle_oci` 8.14.0, `terraform-providers.cloudflare_cloudflare` 5.19.1, sops, just, flake-parts.

**Spec:** `docs/superpowers/specs/2026-09-06-oci-cloudflare-terranix-design.md`

## Global Constraints

- **Import only.** No task may create, modify, or destroy an Oracle or Cloudflare resource. The only writes are to the R2 state bucket. If a plan proposes a create or a destroy, the configuration is wrong — fix the configuration, never apply the plan.
- **The acceptance criterion is an empty plan.** `tofu plan` reporting `No changes.` is the only evidence that a task is done. A plan that "looks close" is a failed task.
- **Commit straight to master.** This repository does not use feature branches. Do not create one, and do not use a git worktree.
- **Conventional commits**, scoped: `<type>(<scope>): <subject>` with scope `modules`, `secrets`, or a hostname. Never mention Claude or any AI tool in a commit message.
- **Run `just fmt` before every commit.** alejandra formats all Nix; CI fails on unformatted files.
- **Never commit a decrypted secret.** The only credential file in the repo is `secrets/sops/infra.yaml`, encrypted. Scratch files go in the scratchpad directory, never in the repo.
- **sops is non-interactive.** Never suggest or use `sops <file>` to open an editor. Build plaintext YAML outside the repo and encrypt it with `sops --encrypt`.
- **Nix code style:** 2-space indent, alejandra formatting, `{...}: {` module headers matching the existing `flake-modules/` files.
- **Provider versions are pinned by nixpkgs, not by HCL.** Never write a `version` constraint into `required_providers`; the plugin mirror is the pin, and a duplicate constraint would drift.

## Working directory conventions

- **Scratchpad** (all throwaway artifacts — discovery output, plaintext credentials, generator scripts): `/tmp/claude-1000/-home-arosenfeld-Code-nixos/a72eecdf-6f18-4987-b949-0853e88383eb/scratchpad`. Referred to below as `$SCRATCH`.
- **OpenTofu working directory** (gitignored, disposable): `infra/.work`.

---

### Task 1: Flake wiring and a terranix configuration that builds

Establishes the evaluation path end to end with no credentials and no backend, so that a failure here is unambiguously a wiring failure.

**Files:**
- Modify: `flake.nix` (inputs block, imports list)
- Create: `flake-modules/infra.nix`
- Create: `infra/default.nix`
- Create: `infra/terraform.nix`
- Modify: `.gitignore`

**Interfaces:**
- Produces: flake outputs `packages.<system>.infra-config` (a `config.tf.json` derivation) and `packages.<system>.tofu` (OpenTofu wrapped with both providers). Every later task consumes both.

- [ ] **Step 1: Add the terranix input**

In `flake.nix`, add to the `inputs` block, after the `niks3` line:

```nix
    terranix.url = "github:terranix/terranix"; # Nix DSL for OpenTofu/Terraform configuration
    terranix.inputs.nixpkgs.follows = "nixpkgs";
```

- [ ] **Step 2: Register the new flake module**

In `flake.nix`, add to the `imports` list, after `./flake-modules/dev.nix`:

```nix
          ./flake-modules/infra.nix
```

- [ ] **Step 3: Write the flake module**

Create `flake-modules/infra.nix`:

```nix
{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }:
    # The OCI provider ships no darwin build in nixpkgs, and infrastructure is
    # only ever applied from a Linux workstation. Guarding here keeps the flake
    # evaluable on aarch64-darwin, which `systems` still lists.
    pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      packages = {
        # The generated OpenTofu configuration. `just tf` links this into
        # infra/.work as config.tf.json.
        infra-config = inputs.terranix.lib.terranixConfiguration {
          inherit pkgs;
          modules = [../infra];
        };

        # OpenTofu with both providers baked into a local plugin mirror, so
        # `tofu init` never contacts a registry and provider versions advance
        # with flake.lock rather than with a lock file in a scratch directory.
        # `just tf` resolves this path explicitly instead of trusting PATH:
        # an ambient tofu would silently fall back to fetching providers.
        tofu = pkgs.opentofu.withPlugins (p: [
          p.oracle_oci
          p.cloudflare_cloudflare
        ]);
      };
    };
}
```

- [ ] **Step 4: Write the terranix entry point**

Create `infra/default.nix`:

```nix
{
  imports = [
    ./terraform.nix
  ];
}
```

- [ ] **Step 5: Write the terraform block**

Create `infra/terraform.nix`. The backend is deliberately absent at this stage — Task 2 adds it, once there are credentials to reach it with.

```nix
{
  # No `version` constraints: nixpkgs pins the provider binaries, and a second
  # constraint here would drift against it on every nixpkgs bump.
  terraform.required_providers = {
    oci.source = "oracle/oci";
    cloudflare.source = "cloudflare/cloudflare";
  };
}
```

- [ ] **Step 6: Ignore the working directory**

Append to `.gitignore`, under the `# Nix build outputs` group:

```
# OpenTofu working directory (generated config, provider cache, lock file)
/infra/.work
```

- [ ] **Step 7: Format and build**

Run:

```bash
just fmt
nix build .#infra-config --out-link "$SCRATCH/infra-config"
```

Expected: build succeeds.

- [ ] **Step 8: Assert the generated JSON is correct**

Run:

```bash
jq -e '
  .terraform.required_providers.oci.source == "oracle/oci"
  and .terraform.required_providers.cloudflare.source == "cloudflare/cloudflare"
  and (.terraform.required_providers.oci | has("version") | not)
' "$SCRATCH/infra-config"
```

Expected: prints `true` and exits 0. A non-zero exit means the module did not
produce the shape later tasks build on.

- [ ] **Step 9: Verify the wrapped OpenTofu resolves providers locally**

Run:

```bash
TOFU=$(nix build --no-link --print-out-paths .#tofu)/bin/tofu
rm -rf "$SCRATCH/tfprobe" && mkdir -p "$SCRATCH/tfprobe"
cp "$SCRATCH/infra-config" "$SCRATCH/tfprobe/config.tf.json"
(cd "$SCRATCH/tfprobe" && "$TOFU" init -input=false)
```

Expected: `OpenTofu has been successfully initialized!`. A warning that the lock
file only covers `linux_amd64` is expected and harmless — the working directory
is disposable.

- [ ] **Step 10: Commit**

```bash
git add flake.nix flake.lock flake-modules/infra.nix infra/ .gitignore
git commit -m "feat(modules): add terranix-backed OpenTofu configuration"
```

---

### Task 2: Credentials, state backend, and the `just tf` recipe

Turns the skeleton into something that can talk to Oracle, Cloudflare and R2.
This task ends the moment `tofu init` succeeds against the real backend.

**Files:**
- Modify: `.sops.yaml` (new creation rule)
- Create: `secrets/sops/infra.yaml` (encrypted)
- Create: `infra/variables.nix`
- Create: `infra/providers.nix`
- Modify: `infra/default.nix` (imports)
- Modify: `infra/terraform.nix` (backend)
- Modify: `justfile` (new `tf` recipe)
- Modify: `flake-modules/dev.nix` (dev shell tools)

**Interfaces:**
- Consumes: `packages.infra-config` and `packages.tofu` from Task 1.
- Produces: `just tf <args>` — runs `tofu <args>` in `infra/.work` with the generated config and decrypted credentials in the environment. Every later task uses `just tf plan` as its verification step.
- Produces: terranix variables `tenancy_ocid`, `user_ocid`, `fingerprint`, `region`, `private_key_path`, `cloudflare_api_token`, all `type = "string"`. Tasks 3 and 4 reference `var.tenancy_ocid`.

- [ ] **Step 1: Gather the credentials (manual, one console session)**

This is the last console trip and cannot be automated. Collect:

1. **OCI API key.** Console → Profile menu → *My profile* → *API keys* → *Add API key* → *Generate API key pair* → download the **private key**. The dialog then shows a configuration-file preview; copy `tenancy`, `user`, `fingerprint`, and `region` out of it.
2. **Cloudflare API token.** Dashboard → *My Profile* → *API Tokens* → *Create Token* → *Custom token*. Permissions: `Zone` → `DNS` → `Edit`, plus `Zone` → `Zone` → `Read`. Zone Resources: include `arsfeld.dev`, `arsfeld.one`, `rosenfeld.one`.
3. **R2 state bucket and token.** Dashboard → *R2* → create a bucket named `tfstate`. **Do not attach a custom domain and do not add a lifecycle rule.** Then *Manage R2 API Tokens* → create a token with *Object Read & Write*, scoped to the `tfstate` bucket. Record the Access Key ID and Secret Access Key.

- [ ] **Step 2: Add the sops creation rule**

In `.sops.yaml`, add after the `raider.yaml` rule. Only the user key is a
recipient — no host ever reads these, and the narrower list follows the
precedent already set by `ntfy-client.yaml`:

```yaml
  # Infrastructure credentials (OCI API key, Cloudflare DNS token, R2 state
  # bucket). Deliberately narrower than every other rule: OpenTofu runs from a
  # workstation only, so no host key is a recipient.
  - path_regex: secrets/sops/infra\.yaml$
    key_groups:
      - age:
          - *user_arosenfeld
```

- [ ] **Step 3: Write the encrypted credentials file**

Build the plaintext outside the repository, encrypt it in, then shred the
source. Never open an editor on it.

```bash
umask 077
cat > "$SCRATCH/infra-plain.yaml" <<EOF
TF_VAR_tenancy_ocid: ocid1.tenancy.oc1..REPLACE
TF_VAR_user_ocid: ocid1.user.oc1..REPLACE
TF_VAR_fingerprint: REPLACE
TF_VAR_region: REPLACE
OCI_PRIVATE_KEY_B64: $(base64 -w0 < /path/to/downloaded/oci_api_key.pem)
TF_VAR_cloudflare_api_token: REPLACE
AWS_ACCESS_KEY_ID: REPLACE
AWS_SECRET_ACCESS_KEY: REPLACE
EOF

# ...replace every REPLACE with the real value, then:
sops --encrypt "$SCRATCH/infra-plain.yaml" > secrets/sops/infra.yaml
shred -u "$SCRATCH/infra-plain.yaml"
```

Verify it round-trips without printing any value:

```bash
sops --decrypt --output-type dotenv secrets/sops/infra.yaml | cut -d= -f1 | sort
```

Expected, exactly these eight lines:

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
OCI_PRIVATE_KEY_B64
TF_VAR_cloudflare_api_token
TF_VAR_fingerprint
TF_VAR_region
TF_VAR_tenancy_ocid
TF_VAR_user_ocid
```

- [ ] **Step 4: Declare the variables**

Create `infra/variables.nix`. The names are not free choices: OpenTofu reads
`TF_VAR_<name>`, and the OCI resource-discovery tool used in Task 3 reads a
fixed set of those same names for its own authentication. Matching them means
one environment serves both.

```nix
let
  secret = {
    type = "string";
    sensitive = true;
  };
  plain.type = "string";
in {
  variable = {
    # Names must match what the OCI resource-discovery tool expects
    # (TF_VAR_tenancy_ocid, TF_VAR_user_ocid, TF_VAR_fingerprint,
    # TF_VAR_region, TF_VAR_private_key_path) so that `just tf` and discovery
    # authenticate from one identical environment.
    tenancy_ocid = plain;
    user_ocid = plain;
    fingerprint = plain;
    region = plain;

    # A PEM cannot survive a line-oriented dotenv round trip, so the key is
    # stored base64-encoded and materialised to a temp file by `just tf`.
    private_key_path = plain;

    cloudflare_api_token = secret;
  };
}
```

- [ ] **Step 5: Configure the providers**

Create `infra/providers.nix`:

```nix
{
  provider = {
    oci = {
      tenancy_ocid = "\${var.tenancy_ocid}";
      user_ocid = "\${var.user_ocid}";
      fingerprint = "\${var.fingerprint}";
      private_key_path = "\${var.private_key_path}";
      region = "\${var.region}";
    };

    cloudflare = {
      api_token = "\${var.cloudflare_api_token}";
    };
  };
}
```

- [ ] **Step 6: Add the state backend**

Replace the whole of `infra/terraform.nix` with:

```nix
{
  terraform = {
    # No `version` constraints: nixpkgs pins the provider binaries, and a second
    # constraint here would drift against it on every nixpkgs bump.
    required_providers = {
      oci.source = "oracle/oci";
      cloudflare.source = "cloudflare/cloudflare";
    };

    # State lives in R2, reached through the S3-compatible API. Credentials come
    # from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the environment: backend
    # configuration cannot reference variables.
    #
    # The account ID is already committed in hosts/basestar/services/niks3.nix,
    # so naming it here adds no exposure. Every skip_* below turns off an
    # AWS-specific validation or metadata call that R2 does not implement;
    # use_lockfile gets state locking from R2's conditional PUT support, which
    # is why no DynamoDB substitute is needed.
    #
    # Never add an R2 lifecycle rule to this bucket. Object versioning is the
    # only undo available for a corrupted state file.
    backend.s3 = {
      bucket = "tfstate";
      key = "nixos-infra.tfstate";
      region = "auto";
      endpoints.s3 = "https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com";
      use_path_style = true;
      use_lockfile = true;
      skip_credentials_validation = true;
      skip_region_validation = true;
      skip_requesting_account_id = true;
      skip_metadata_api_check = true;
      skip_s3_checksum = true;
    };
  };
}
```

- [ ] **Step 7: Wire the new modules in**

Replace `infra/default.nix` with:

```nix
{
  imports = [
    ./terraform.nix
    ./variables.nix
    ./providers.nix
  ];
}
```

- [ ] **Step 8: Add the `just tf` recipe**

Append to `justfile`, after the `cache HOST` recipe:

```just
# === Infrastructure (OpenTofu via terranix) ===
# `just tf plan`, `just tf apply`, `just tf state list` — anything tofu accepts.
# There is deliberately no `tf-destroy` recipe: `just tf destroy` still reaches
# it, but it has to be typed in full rather than sitting in `just --list`.
tf *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail

    workdir=infra/.work
    mkdir -p "$workdir"

    # Resolve the wrapped OpenTofu explicitly. An ambient `tofu` on PATH (the
    # system one comes from nixpkgs-unstable) carries no provider mirror and
    # would silently fetch providers from the registry instead.
    tofu=$(nix build --no-link --print-out-paths '.#tofu')/bin/tofu

    # Link, don't copy: the config is a store path, and a stale copy after an
    # edit is the single most confusing failure mode here.
    ln -sf "$(nix build --no-link --print-out-paths '.#infra-config')" "$workdir/config.tf.json"

    # The PEM is the one credential that cannot travel as an environment
    # variable, so decode it to a private temp file for the life of the command.
    keyfile=$(mktemp -t oci-api-key-XXXXXX.pem)
    trap 'rm -f "$keyfile"' EXIT
    chmod 600 "$keyfile"

    # `export "$line"` rather than `eval`: each dotenv line is one shell word,
    # so values containing spaces survive without a quoting round trip.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        export "${line}"
    done < <(sops --decrypt --output-type dotenv secrets/sops/infra.yaml)

    printf '%s' "$OCI_PRIVATE_KEY_B64" | base64 -d > "$keyfile"
    export TF_VAR_private_key_path="$keyfile"

    cd "$workdir"
    # Init on every invocation. It is cheap against a filesystem mirror, and it
    # removes the stale-lock failure that otherwise appears whenever nixpkgs
    # bumps a provider under a working directory that outlived it.
    "$tofu" init -input=false -upgrade >/dev/null
    exec "$tofu" {{ ARGS }}
```

- [ ] **Step 9: Add the tools to the dev shell**

In `flake-modules/dev.nix`, inside the `pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux` list, alongside `disko`:

```nix
          # OpenTofu with the OCI and Cloudflare providers baked in, and the OCI
          # CLI for ad-hoc inspection. `just tf` resolves its own tofu from
          # `.#tofu` rather than PATH; these are here for interactive use.
          self'.packages.tofu
          oci-cli
```

This needs `self'` in the `perSystem` argument set — it is already there.

- [ ] **Step 10: Format, then verify the backend is reachable**

Run:

```bash
just fmt
just tf version
```

Expected: OpenTofu prints its version (1.11.8). This exercises the whole
path — terranix evaluation, credential decryption, key materialisation, backend
init against R2.

If init fails with `AccessDenied`, the R2 token is not scoped to the `tfstate`
bucket. If it fails with `NoSuchBucket`, the bucket name or the account ID in
the endpoint is wrong.

- [ ] **Step 11: Verify the providers authenticate**

Run:

```bash
just tf providers
```

Expected: both `registry.terraform.io/oracle/oci` and
`registry.terraform.io/cloudflare/cloudflare` are listed.

- [ ] **Step 12: Commit**

```bash
just fmt
git add .sops.yaml secrets/sops/infra.yaml infra/ justfile flake-modules/dev.nix
git commit -m "feat(secrets): add infrastructure credentials and the tf recipe"
```

---

### Task 3: Discover and adopt the OCI network

Runs resource discovery once, then writes the network half of the tenancy as
terranix and imports it.

**Files:**
- Create: `infra/oci/network.nix`
- Modify: `infra/default.nix` (imports)

**Interfaces:**
- Consumes: `just tf` from Task 2; variables `tenancy_ocid` and `region`.
- Produces: resources `oci_core_vcn.main`, `oci_core_internet_gateway.main`, `oci_core_route_table.main`, `oci_core_security_list.main`, `oci_core_subnet.main`. Task 4 references `oci_core_subnet.main.id`.

- [ ] **Step 1: Run resource discovery into the scratchpad**

Discovery authenticates from the same `TF_VAR_*` environment `just tf` builds,
which is why the variable names were chosen to match. Run:

```bash
OCI_PROVIDER=$(nix build --no-link --print-out-paths \
  --impure --expr 'let f = builtins.getFlake (toString ./.); in f.inputs.nixpkgs.legacyPackages.x86_64-linux.terraform-providers.oracle_oci')
RD=$(find "$OCI_PROVIDER" -type f -name 'terraform-provider-oci_*')

keyfile=$(mktemp -t oci-api-key-XXXXXX.pem); chmod 600 "$keyfile"
while IFS= read -r line; do [ -n "$line" ] || continue; export "${line}"; done \
  < <(sops --decrypt --output-type dotenv secrets/sops/infra.yaml)
printf '%s' "$OCI_PRIVATE_KEY_B64" | base64 -d > "$keyfile"
export TF_VAR_private_key_path="$keyfile"

rm -rf "$SCRATCH/rd" && mkdir -p "$SCRATCH/rd"
"$RD" -command=export \
  -compartment_id="$TF_VAR_tenancy_ocid" \
  -services=core \
  -output_path="$SCRATCH/rd" \
  -parallelism=4

rm -f "$keyfile"
```

Expected: `$SCRATCH/rd` contains generated `.tf` files. `-services=core`
restricts discovery to compute and networking, which is the whole scope here.

- [ ] **Step 2: Read the discovered network resources**

Run:

```bash
cat "$SCRATCH/rd"/*virtual_network*.tf 2>/dev/null || cat "$SCRATCH/rd"/*.tf
```

Record, for each resource, its type, the attribute values, and its OCID. The
OCIDs are what the `import` blocks need. Note in particular every ingress and
egress rule on the security list, in order — order is significant to OpenTofu
and a reordered list produces a permanent diff.

- [ ] **Step 3: Write the network module**

Create `infra/oci/network.nix`. The structure below is the shape to fill in
from discovery — replace every `REPLACE_*` with the discovered value, and add
one `ingress_security_rules` entry per discovered rule, in the discovered
order. Do not invent rules, and do not tidy the ones that exist: this task
adopts reality, and any cleanup is a separate, later change.

```nix
{
  resource = {
    oci_core_vcn.main = {
      compartment_id = "\${var.tenancy_ocid}";
      cidr_blocks = ["REPLACE_CIDR"];
      display_name = "REPLACE_NAME";
      dns_label = "REPLACE_DNS_LABEL";
      # basestar's entire network path hangs off this VCN.
      lifecycle = [{prevent_destroy = true;}];
    };

    oci_core_internet_gateway.main = {
      compartment_id = "\${var.tenancy_ocid}";
      vcn_id = "\${oci_core_vcn.main.id}";
      display_name = "REPLACE_NAME";
      enabled = true;
    };

    oci_core_route_table.main = {
      compartment_id = "\${var.tenancy_ocid}";
      vcn_id = "\${oci_core_vcn.main.id}";
      display_name = "REPLACE_NAME";
      route_rules = [
        {
          destination = "0.0.0.0/0";
          destination_type = "CIDR_BLOCK";
          network_entity_id = "\${oci_core_internet_gateway.main.id}";
        }
      ];
    };

    # This is the firewall CLAUDE.md refers to as "the upstream OCI/cloud
    # firewall". The host firewall's base allowlist is 22/80/443; this list is
    # what actually decides what reaches basestar from the internet.
    oci_core_security_list.main = {
      compartment_id = "\${var.tenancy_ocid}";
      vcn_id = "\${oci_core_vcn.main.id}";
      display_name = "REPLACE_NAME";
      egress_security_rules = [
        {
          destination = "0.0.0.0/0";
          destination_type = "CIDR_BLOCK";
          protocol = "all";
        }
      ];
      ingress_security_rules = [
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          tcp_options = [
            {
              min = 443;
              max = 443;
            }
          ];
        }
        # ...one entry per discovered rule, in discovered order.
      ];
    };

    oci_core_subnet.main = {
      compartment_id = "\${var.tenancy_ocid}";
      vcn_id = "\${oci_core_vcn.main.id}";
      cidr_block = "REPLACE_CIDR";
      display_name = "REPLACE_NAME";
      dns_label = "REPLACE_DNS_LABEL";
      route_table_id = "\${oci_core_route_table.main.id}";
      security_list_ids = ["\${oci_core_security_list.main.id}"];
      lifecycle = [{prevent_destroy = true;}];
    };
  };

  # Adoption. These blocks are no-ops once the resources are in state; they are
  # kept as the record of which real object each resource adopted, and they make
  # rebuilding state from scratch a `tofu apply` rather than an archaeology
  # exercise.
  import = [
    {
      to = "oci_core_vcn.main";
      id = "REPLACE_VCN_OCID";
    }
    {
      to = "oci_core_internet_gateway.main";
      id = "REPLACE_IG_OCID";
    }
    {
      to = "oci_core_route_table.main";
      id = "REPLACE_RT_OCID";
    }
    {
      to = "oci_core_security_list.main";
      id = "REPLACE_SL_OCID";
    }
    {
      to = "oci_core_subnet.main";
      id = "REPLACE_SUBNET_OCID";
    }
  ];
}
```

- [ ] **Step 4: Wire it in**

In `infra/default.nix`, add `./oci/network.nix` to the imports list:

```nix
{
  imports = [
    ./terraform.nix
    ./variables.nix
    ./providers.nix
    ./oci/network.nix
  ];
}
```

- [ ] **Step 5: Plan and read the import preview**

Run:

```bash
just fmt
just tf plan
```

Expected on the first run: five resources reported as **imported**, and zero to
add, zero to change, zero to destroy. Any `will be created` line means an
import block is missing or its OCID is wrong — **do not apply**.

- [ ] **Step 6: Apply the import**

Only once Step 5 shows imports and nothing else:

```bash
just tf apply
```

Expected: `Apply complete! Resources: 5 imported, 0 added, 0 changed, 0 destroyed.`

- [ ] **Step 7: Verify the plan is now empty**

Run:

```bash
just tf plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

If instead there are changes, the configuration disagrees with reality —
usually a reordered security-list rule, a defaulted field discovery omitted, or
a `display_name` mismatch. Fix `network.nix`, never the infrastructure.

- [ ] **Step 8: Commit**

```bash
git add infra/
git commit -m "feat(basestar): adopt the Oracle Cloud network into OpenTofu"
```

---

### Task 4: Adopt the basestar instance

**Files:**
- Create: `infra/oci/basestar.nix`
- Modify: `infra/default.nix` (imports)

**Interfaces:**
- Consumes: `oci_core_subnet.main.id` from Task 3.
- Produces: `oci_core_instance.basestar`. Nothing later depends on it.

- [ ] **Step 1: Read the discovered instance**

From the Task 3 discovery output:

```bash
grep -A40 'resource "oci_core_instance"' "$SCRATCH/rd"/*.tf
grep -rn 'public_ip\|reserved\|oci_core_public_ip' "$SCRATCH/rd"/*.tf
```

Record: shape, `shape_config` (OCPUs and memory), `availability_domain`,
`source_details` (image OCID and boot volume size), `display_name`,
`create_vnic_details`, and the instance OCID.

Also determine whether the public IP `168.138.71.109` is **ephemeral** or
**reserved** — an `oci_core_public_ip` resource with `lifetime = "RESERVED"`
means reserved; its absence means ephemeral, attached to the VNIC. Record which
it is; the spec calls for reporting this, not changing it.

- [ ] **Step 2: Write the instance module**

Create `infra/oci/basestar.nix`, filling in from discovery:

```nix
{
  resource.oci_core_instance.basestar = {
    compartment_id = "\${var.tenancy_ocid}";
    availability_domain = "REPLACE_AD";
    display_name = "REPLACE_NAME";
    shape = "REPLACE_SHAPE"; # e.g. VM.Standard.A1.Flex

    shape_config = [
      {
        ocpus = 4;
        memory_in_gbs = 24;
      }
    ];

    create_vnic_details = [
      {
        subnet_id = "\${oci_core_subnet.main.id}";
        assign_public_ip = true;
        display_name = "REPLACE_VNIC_NAME";
        hostname_label = "REPLACE_HOSTNAME_LABEL";
      }
    ];

    source_details = [
      {
        source_type = "image";
        source_id = "REPLACE_IMAGE_OCID";
        boot_volume_size_in_gbs = "100";
      }
    ];

    lifecycle = [
      {
        # This is the machine. A plan that would replace or destroy it should
        # fail to generate, not fail halfway through applying.
        prevent_destroy = true;

        # basestar was infected onto a stock Oracle image and has been NixOS
        # ever since; the image OCID is now pure history. Oracle retires image
        # OCIDs on its own schedule, and an unguarded source_details would read
        # that retirement as "replace the instance".
        ignore_changes = ["source_details"];
      }
    ];
  };

  import = [
    {
      to = "oci_core_instance.basestar";
      id = "REPLACE_INSTANCE_OCID";
    }
  ];
}
```

- [ ] **Step 3: Add the boot volume and public IP, if discovery found them as separate resources**

Oracle models the boot volume as its own `oci_core_boot_volume` once the
instance has been stopped and started, or if it was ever resized; a reserved
public IP is always its own `oci_core_public_ip`. Whether either exists here is
a discovery finding, not an assumption.

If `$SCRATCH/rd` contains an `oci_core_boot_volume` resource, add to
`infra/oci/basestar.nix`:

```nix
  resource.oci_core_boot_volume.basestar = {
    compartment_id = "\${var.tenancy_ocid}";
    availability_domain = "REPLACE_AD";
    display_name = "REPLACE_NAME";
    size_in_gbs = "100";
    # basestar's root filesystem. Nothing about a plan should be able to remove
    # it, including a plan that means to replace it with an identical one.
    lifecycle = [{prevent_destroy = true;}];
  };
```

and a matching entry in the `import` list. If discovery found an
`oci_core_public_ip` with `lifetime = "RESERVED"`, add that too, likewise with
`prevent_destroy` — it is the address `niks3.arsfeld.dev` resolves to, and the
deploy pipeline's push path depends on it.

If neither appears in the discovery output, add neither, and record for Task 7
Step 5 that the public IP is **ephemeral**.

- [ ] **Step 4: Wire it in**

Add `./oci/basestar.nix` to the imports list in `infra/default.nix`.

- [ ] **Step 5: Plan**

```bash
just fmt
just tf plan
```

Expected: one resource imported, zero added, zero changed, **zero destroyed**.
If the plan proposes destroying or replacing the instance, stop — the
`prevent_destroy` guard should have blocked it, and its absence means the
lifecycle block did not take effect.

- [ ] **Step 6: Apply and confirm an empty plan**

```bash
just tf apply
just tf plan
```

Expected: `Apply complete! Resources: 1 imported...` then
`No changes. Your infrastructure matches the configuration.`

- [ ] **Step 7: Confirm the guard actually works**

Prove the safety rail rather than assuming it. Run:

```bash
just tf plan -destroy
```

Expected: **an error**, naming `oci_core_instance.basestar` and
`prevent_destroy`. If this instead prints a destroy plan, the guard is not
wired up — fix it before committing.

- [ ] **Step 8: Commit**

```bash
git add infra/
git commit -m "feat(basestar): adopt the Oracle Cloud instance into OpenTofu"
```

---

### Task 5: Adopt the arsfeld.dev DNS zone

The largest zone and the one with the load-bearing record. Doing it alone first
means the generator and the TXT-quoting question get settled on one zone before
being applied to the rest.

**Files:**
- Create: `infra/dns/arsfeld-dev.nix`
- Modify: `infra/default.nix` (imports)

**Interfaces:**
- Consumes: `just tf` from Task 2.
- Produces: `cloudflare_dns_record.<slug>` resources. Task 6 follows the identical pattern and slug convention.

- [ ] **Step 1: Write the generator script**

Hand-transcribing 50 records invites exactly the kind of typo an empty plan
would then have to catch. Generate them instead. This script is throwaway — it
lives in the scratchpad, not the repo, because it runs three times and the
reviewed artifact is its Nix output.

The script below has already been run against `arsfeld.one` during planning: its
output parses as Nix, passes `alejandra --check` unmodified, and correctly
disambiguates the two apex MX records into `mx_arsfeld_one_1` and
`mx_arsfeld_one_2`. It emits `proxied` only for A/AAAA/CNAME and `priority` only
for MX, because sending either on a record type that does not accept it produces
a permanent diff.

```bash
cat > "$SCRATCH/cf2nix.sh" <<'SCRIPT'
#!/usr/bin/env bash
# usage: cf2nix.sh <zone_name> <zone_id>
set -euo pipefail
zone_name=$1; zone_id=$2

eval "$(sops --decrypt --extract '["cloudflare"]' secrets/sops/common.yaml | sed 's/^/export /')"

curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=100" \
  -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
| jq -r --arg zid "$zone_id" '
  def slug: gsub("[^a-zA-Z0-9]"; "_") | ascii_downcase;
  def nixstr: "\"" + (tostring
      | gsub("\\\\"; "\\\\\\\\")
      | gsub("\""; "\\\"")
      | gsub("\\$"; "\\\\$")) + "\"";
  def base: (.type + "_" + .name) | slug;

  # Two records can share a type and name (multiple MX at the apex, several TXT
  # verifications). Nix rejects a duplicate attribute, so disambiguate with an
  # index while leaving unique names clean.
  [ (.result | sort_by(.type, .name, .content))
    | group_by(base)[]
    | (if length == 1
       then [ .[0] + {_slug: (.[0] | base)} ]
       else to_entries | map(.value + {_slug: ((.value | base) + "_" + ((.key + 1) | tostring))})
       end)
    | .[]
  ] | sort_by(._slug) as $rs
  | "{",
    "  resource.cloudflare_dns_record = {",
    ( $rs[] | "    " + ._slug + " = {",
        "      zone_id = " + ($zid | nixstr) + ";",
        "      name = " + (.name | nixstr) + ";",
        "      type = " + (.type | nixstr) + ";",
        "      content = " + (.content | nixstr) + ";",
        "      ttl = " + (.ttl | tostring) + ";",
        (if (.type | IN("A","AAAA","CNAME")) then "      proxied = " + (.proxied | tostring) + ";" else empty end),
        (if .type == "MX" then "      priority = " + (.priority | tostring) + ";" else empty end),
        (if (.comment // "") != "" then "      comment = " + (.comment | nixstr) + ";" else empty end),
        "    };" ),
    "  };",
    "",
    "  import = [",
    ( $rs[] | "    {",
        "      to = \"cloudflare_dns_record." + ._slug + "\";",
        "      id = " + (($zid + "/" + .id) | nixstr) + ";",
        "    }" ),
    "  ];",
    "}"
'
SCRIPT
chmod +x "$SCRATCH/cf2nix.sh"
```

- [ ] **Step 2: Generate the zone module**

```bash
"$SCRATCH/cf2nix.sh" arsfeld.dev 5b658a2265b2562c6f51ac93de8d21bf > infra/dns/arsfeld-dev.nix
just fmt
```

- [ ] **Step 3: Read every generated record**

This is a review step, not a formality. Open `infra/dns/arsfeld-dev.nix` and
check:

- The `niks3` A record has `proxied = false`. `CLAUDE.md` documents why: a
  proxied record serves GitHub-hosted runners a managed challenge, and CI can
  then never push a closure. If this record is wrong, deploys break in a way
  whose error message names niks3 rather than DNS.
- TXT record content survived intact, including any embedded quotes in SPF,
  DKIM and verification records.
- MX records carry `priority`.
- `ttl = 1` means automatic and is correct where Cloudflare reports it.

- [ ] **Step 4: Add a header comment**

Prepend to `infra/dns/arsfeld-dev.nix`:

```nix
# arsfeld.dev — basestar's public zone.
#
# Generated from the Cloudflare API and reviewed by hand. Records are adopted,
# not authored: this file describes what already exists.
#
# The niks3 A record must stay unproxied (grey cloud). A proxied record serves
# GitHub-hosted runners a managed challenge, which silently breaks CI's push to
# the binary cache. See CLAUDE.md.
```

- [ ] **Step 5: Wire it in**

Add `./dns/arsfeld-dev.nix` to the imports list in `infra/default.nix`.

- [ ] **Step 6: Plan**

```bash
just fmt
just tf plan
```

Expected: 23 records imported, zero added, zero changed, zero destroyed.

A `will be created` line means a record exists in Cloudflare that the import
block does not name — regenerate. A `will be updated` line after import means a
field round-tripped wrong, most often TXT quoting; fix the content in the Nix.

- [ ] **Step 7: Apply and confirm an empty plan**

```bash
just tf apply
just tf plan
```

Expected: `Apply complete! Resources: 23 imported...` then `No changes.`

- [ ] **Step 8: Verify the niks3 record specifically**

```bash
just tf state show 'cloudflare_dns_record.a_niks3_arsfeld_dev' | grep -E 'content|proxied'
```

Expected: `content = "168.138.71.109"` and `proxied = false`.

- [ ] **Step 9: Commit**

```bash
git add infra/
git commit -m "feat(basestar): adopt the arsfeld.dev DNS zone into OpenTofu"
```

---

### Task 6: Adopt the arsfeld.one and rosenfeld.one zones

Mechanically identical to Task 5, with the generator already proven.

**Files:**
- Create: `infra/dns/arsfeld-one.nix`
- Create: `infra/dns/rosenfeld-one.nix`
- Modify: `infra/default.nix` (imports)

**Interfaces:**
- Consumes: `$SCRATCH/cf2nix.sh` and the slug convention from Task 5.

- [ ] **Step 1: Generate both zones**

```bash
"$SCRATCH/cf2nix.sh" arsfeld.one 877dc2cb2972842c423b9c9851d95cc7 > infra/dns/arsfeld-one.nix
"$SCRATCH/cf2nix.sh" rosenfeld.one 1c77692238095c6a5a263ab71c301ed8 > infra/dns/rosenfeld-one.nix
just fmt
```

- [ ] **Step 2: Add header comments**

Prepend to `infra/dns/arsfeld-one.nix`:

```nix
# arsfeld.one — galactica's internal zone, fronted by its cloudflared tunnel.
#
# Generated from the Cloudflare API and reviewed by hand. Records are adopted,
# not authored: this file describes what already exists.
#
# The wildcard record is the tunnel's ingress. Adding a public hostname through
# the Zero Trust dashboard creates a record outside this file, which the next
# apply would then delete.
```

Prepend to `infra/dns/rosenfeld-one.nix`:

```nix
# rosenfeld.one — the zone behind constellation.sites.rosenfeld-one.
#
# Generated from the Cloudflare API and reviewed by hand. Records are adopted,
# not authored: this file describes what already exists.
```

- [ ] **Step 3: Review both files**

Same checks as Task 5 Step 3: TXT content intact, MX records carry `priority`,
and every `proxied` value matches what Cloudflare reports today. Pay attention
to the `arsfeld.one` wildcard CNAME — it points at the cloudflared tunnel and
must keep its current proxied setting.

- [ ] **Step 4: Wire both in**

`infra/default.nix` reaches its final form:

```nix
{
  imports = [
    ./terraform.nix
    ./variables.nix
    ./providers.nix
    ./oci/network.nix
    ./oci/basestar.nix
    ./dns/arsfeld-dev.nix
    ./dns/arsfeld-one.nix
    ./dns/rosenfeld-one.nix
  ];
}
```

- [ ] **Step 5: Plan, apply, confirm empty**

```bash
just fmt
just tf plan     # expect 27 imported, 0 added, 0 changed, 0 destroyed
just tf apply
just tf plan     # expect: No changes.
```

- [ ] **Step 6: Commit**

```bash
git add infra/
git commit -m "feat(modules): adopt the arsfeld.one and rosenfeld.one DNS zones"
```

---

### Task 7: Document it and verify the whole thing

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Full verification from a clean working directory**

Prove the whole path reconstructs from nothing but the repo and the state
bucket:

```bash
rm -rf infra/.work
just tf plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

This is the plan's overall acceptance criterion. If it does not hold, no
documentation should be written yet.

- [ ] **Step 2: Confirm the destroy guard once more**

```bash
just tf plan -destroy
```

Expected: an error naming `prevent_destroy`.

- [ ] **Step 3: Document it in CLAUDE.md**

Add a section after "Secret Management":

````markdown
### Infrastructure (OpenTofu via terranix)

The Oracle Cloud tenancy behind basestar and the three in-use Cloudflare DNS
zones (`arsfeld.dev`, `arsfeld.one`, `rosenfeld.one`) are managed as code under
`infra/`, written as terranix Nix modules rather than HCL.

```bash
just tf plan      # anything tofu accepts: plan, apply, state list, ...
just tf apply
```

`just tf` rebuilds `config.tf.json` from `.#infra-config`, links it into the
gitignored `infra/.work`, decrypts `secrets/sops/infra.yaml` into the
environment, and runs an OpenTofu resolved from `.#tofu` — never from PATH,
because the ambient `tofu` carries no provider mirror and would fetch providers
from the registry instead.

Things worth knowing before touching it:

- **Everything here was imported, not created.** The `import` blocks are kept
  after adoption rather than deleted: they are the record of which real object
  each resource adopted, and they make rebuilding lost state an apply rather
  than an archaeology exercise.
- **The instance, boot volume, VCN and subnet carry `prevent_destroy`.** A plan
  that would delete basestar fails to generate. `just tf plan -destroy` erroring
  out is the expected behaviour, not a bug.
- **The instance ignores `source_details`.** basestar was infected onto a stock
  Oracle image years ago; Oracle retires image OCIDs on its own schedule, and an
  unguarded configuration would read that retirement as "replace the machine".
- **Adding a tunnel hostname in the Zero Trust dashboard creates a DNS record
  behind OpenTofu's back**, which the next apply deletes. Add it to
  `infra/dns/arsfeld-one.nix` instead, or import it afterwards.
- **State lives in the R2 bucket `tfstate`**, with locking via conditional PUT.
  Never add an R2 lifecycle rule to it — object versioning is the only undo a
  corrupted state file gets. Same reasoning as `nix-cache`.
- **`secrets/sops/infra.yaml` has only the user key as a recipient.** No host
  reads it; OpenTofu runs from a workstation.
- Provider versions come from nixpkgs, not from `required_providers`. There is
  deliberately no version constraint in the Nix — the plugin mirror is the pin.
````

- [ ] **Step 4: Add a line to the README**

In the commands section of `README.md`, next to the deploy recipes:

```markdown
| `just tf plan` | Plan changes to the Oracle Cloud / Cloudflare DNS infrastructure |
| `just tf apply` | Apply them |
```

- [ ] **Step 5: Report the public IP finding**

State plainly, in the final summary to the user, whether `168.138.71.109` is
reserved or ephemeral, as recorded in Task 4 Steps 1 and 3. If ephemeral, say so
explicitly and note that converting it to a reserved IP is a real change rather
than an import, and therefore was not performed.

- [ ] **Step 6: Commit**

```bash
just fmt
git add CLAUDE.md README.md
git commit -m "docs(modules): document the OpenTofu infrastructure workflow"
```

---

## Rollback

State is in R2 with object versioning; the repository is in git. To back out
entirely: `git revert` the seven commits and delete the `tfstate` bucket. No
Oracle or Cloudflare resource is modified by any task in this plan, so backing
out changes nothing about the running infrastructure — which is the whole point
of an import-only adoption.
