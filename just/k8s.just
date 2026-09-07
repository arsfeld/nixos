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
    ssh root@basestar.bat-boa.ts.net cat /etc/rancher/k3s/k3s.yaml \
      | sed 's|https://127.0.0.1:6443|https://basestar.bat-boa.ts.net:6443|' \
      > '{{ KUBECONFIG_PATH }}'
    chmod 600 '{{ KUBECONFIG_PATH }}'
    echo "wrote {{ KUBECONFIG_PATH }}"

# `just k8s::k get pods -A`, `just k8s::k logs -n foo bar` - anything kubectl takes.
k *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f '{{ KUBECONFIG_PATH }}' ]; then
        echo "no kubeconfig; run: just k8s::kubeconfig" >&2
        exit 1
    fi
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
    kubectl=$(nix build --no-link --print-out-paths 'nixpkgs#kubectl^out')/bin/kubectl
    KUBECONFIG='{{ KUBECONFIG_PATH }}' "$kubectl" apply \
        --server-side --validate=strict -f '{{ PATH }}'
