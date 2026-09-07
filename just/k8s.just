# Cluster access for basestar's k3s.
#
# Shaped like `just tf`: the tool is resolved explicitly and the recipe is a
# passthrough, so anything kubectl accepts works without a recipe per verb.

KUBECONFIG_PATH := justfile_directory() / ".k8s/basestar.yaml"

# Fetch the cluster credentials from basestar and rewrite the server address.
# k3s writes 127.0.0.1 into its own kubeconfig, which is correct on the node
# and useless anywhere else.
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p "$(dirname '{{ KUBECONFIG_PATH }}')"

    # Create the file with restrictive permissions before any credential
    # material lands in it. A bare `> '{{ KUBECONFIG_PATH }}'` on first
    # creation would open the file at the process umask (commonly 0644),
    # briefly exposing live cluster credentials for a public-facing host;
    # `chmod` afterwards only closes that window, it doesn't prevent it.
    : > '{{ KUBECONFIG_PATH }}'
    chmod 600 '{{ KUBECONFIG_PATH }}'

    ssh root@basestar.bat-boa.ts.net cat /etc/rancher/k3s/k3s.yaml \
      | sed 's|https://127.0.0.1:6443|https://basestar.bat-boa.ts.net:6443|' \
      > '{{ KUBECONFIG_PATH }}'

    # sed no-ops silently if the string it's looking for isn't there (a k3s
    # version change, a port override, IPv6 ::1) - `set -e` can't see that,
    # so verify the rewrite actually took instead of trusting sed's exit code.
    if ! grep -q 'https://basestar.bat-boa.ts.net:6443' '{{ KUBECONFIG_PATH }}'; then
        echo "kubeconfig fetched but the server address rewrite didn't match - check /etc/rancher/k3s/k3s.yaml on basestar for an unexpected server URL" >&2
        exit 1
    fi

    echo "wrote {{ KUBECONFIG_PATH }}"

# `just k8s::k get pods -A`, `just k8s::k logs -n foo bar` - anything kubectl takes.
k *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f '{{ KUBECONFIG_PATH }}' ]; then
        echo "no kubeconfig; run: just k8s::kubeconfig" >&2
        exit 1
    fi
    # `^out` skips kubectl's separate `man` output; plain `nixpkgs#kubectl`
    # resolves to two store paths, which breaks the single-path assumption below.
    kubectl=$(nix build --no-link --print-out-paths 'nixpkgs#kubectl^out')/bin/kubectl
    KUBECONFIG='{{ KUBECONFIG_PATH }}' "$kubectl" {{ ARGS }}

# Apply a manifest or kustomization from the workstation - the fast lane.
#
# --server-side --validate=strict is what makes plain attrsets safe without a
# typed schema layer: the API server rejects unknown fields, so a typo'd
# spec.replica fails loudly here instead of silently doing nothing.
apply PATH:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f '{{ KUBECONFIG_PATH }}' ]; then
        echo "no kubeconfig; run: just k8s::kubeconfig" >&2
        exit 1
    fi
    # `^out` skips kubectl's separate `man` output; plain `nixpkgs#kubectl`
    # resolves to two store paths, which breaks the single-path assumption below.
    kubectl=$(nix build --no-link --print-out-paths 'nixpkgs#kubectl^out')/bin/kubectl
    KUBECONFIG='{{ KUBECONFIG_PATH }}' "$kubectl" apply \
        --server-side --validate=strict -f '{{ PATH }}'
