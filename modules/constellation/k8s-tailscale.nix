# Constellation Tailscale Kubernetes Operator module
#
# This module deploys the Tailscale Kubernetes Operator to enable service
# exposure via Tailscale. It replaces the tsnsrv approach with native
# Kubernetes integration.
#
# Key features:
# - Helm chart deployment via k3s manifests
# - OAuth credential management via sops-nix
# - Automatic service exposure via annotations
# - Support for Tailscale Funnel for public access
#
# Service exposure:
# - Add annotation `tailscale.com/expose: "true"` to expose via Tailscale
# - Add annotation `tailscale.com/funnel: "true"` for public internet access
# - Services get hostnames like `<service>.bat-boa.ts.net`
#
# Usage:
#   constellation.k8s-tailscale = {
#     enable = true;
#   };
#
# Prerequisites:
# - Tailscale OAuth client with appropriate scopes
# - Tags `tag:k8s-operator` and `tag:k8s` in tailnet policy
{
  lib,
  config,
  pkgs,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.k8s-tailscale;
  k3sCfg = config.constellation.k3s;
in {
  options.constellation.k8s-tailscale = {
    enable = mkEnableOption "Tailscale Kubernetes Operator for service exposure";

    namespace = mkOption {
      type = types.str;
      default = "tailscale";
      description = "Kubernetes namespace for the Tailscale operator.";
    };

    chartVersion = mkOption {
      type = types.str;
      default = "1.78.0";
      description = "Version of the Tailscale operator Helm chart.";
    };

    image = {
      repository = mkOption {
        type = types.str;
        default = "tailscale/k8s-operator";
        description = "Image repository for the Tailscale operator.";
      };

      tag = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Image tag. If null, uses chart default.";
      };
    };

    proxyImage = {
      repository = mkOption {
        type = types.str;
        default = "tailscale/tailscale";
        description = "Image repository for Tailscale proxies.";
      };

      tag = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Image tag for proxies. If null, uses chart default.";
      };
    };

    defaultTags = mkOption {
      type = types.listOf types.str;
      default = ["tag:k8s"];
      description = ''
        Default tags applied to Tailscale devices created by the operator.
        These tags must be defined in your tailnet policy file.
      '';
    };

    apiServerProxyConfig = mkOption {
      type = types.enum ["noauth" "true" "false"];
      default = "false";
      description = ''
        Configure Kubernetes API server proxy:
        - "false": Disabled (default)
        - "true": Enabled with auth
        - "noauth": Enabled without additional auth
      '';
    };
  };

  config = mkIf (cfg.enable && k3sCfg.enable && k3sCfg.role == "server") {
    # Require sops for OAuth credentials
    assertions = [
      {
        assertion = config.constellation.sops.enable;
        message = "constellation.k8s-tailscale requires constellation.sops.enable = true";
      }
    ];

    # OAuth credentials from sops
    sops.secrets.tailscale-k8s-oauth-client-id = {
      sopsFile = config.constellation.sops.commonSopsFile;
      mode = "0400";
    };
    sops.secrets.tailscale-k8s-oauth-client-secret = {
      sopsFile = config.constellation.sops.commonSopsFile;
      mode = "0400";
    };

    # Deploy via k3s manifests
    constellation.k3s.manifests = {
      # Namespace
      "tailscale-namespace" = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = cfg.namespace;
      };

      # OAuth Secret (populated by systemd service)
      "tailscale-operator-oauth" = {
        apiVersion = "v1";
        kind = "Secret";
        metadata = {
          name = "operator-oauth";
          namespace = cfg.namespace;
        };
        type = "Opaque";
        # Placeholder - actual values set by k3s-tailscale-oauth-sync service
        stringData = {
          client_id = "PLACEHOLDER";
          client_secret = "PLACEHOLDER";
        };
      };

      # Service Account
      "tailscale-operator-sa" = {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = "operator";
          namespace = cfg.namespace;
        };
      };

      # ClusterRole for operator
      "tailscale-operator-role" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        metadata.name = "tailscale-operator";
        rules = [
          {
            apiGroups = [""];
            resources = ["events" "services" "services/status" "pods" "nodes" "secrets" "serviceaccounts" "configmaps"];
            verbs = ["get" "list" "watch" "create" "update" "patch" "delete"];
          }
          {
            apiGroups = ["apps"];
            resources = ["deployments" "statefulsets" "daemonsets"];
            verbs = ["get" "list" "watch" "create" "update" "patch" "delete"];
          }
          {
            apiGroups = ["networking.k8s.io"];
            resources = ["ingresses" "ingresses/status" "ingressclasses"];
            verbs = ["get" "list" "watch" "create" "update" "patch" "delete"];
          }
          {
            apiGroups = ["coordination.k8s.io"];
            resources = ["leases"];
            verbs = ["get" "list" "watch" "create" "update" "patch" "delete"];
          }
          {
            apiGroups = ["tailscale.com"];
            resources = ["*"];
            verbs = ["*"];
          }
          {
            apiGroups = ["discovery.k8s.io"];
            resources = ["endpointslices"];
            verbs = ["get" "list" "watch"];
          }
        ];
      };

      # ClusterRoleBinding
      "tailscale-operator-rolebinding" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata.name = "tailscale-operator";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "tailscale-operator";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "operator";
            namespace = cfg.namespace;
          }
        ];
      };

      # Role for operator in its namespace
      "tailscale-operator-namespace-role" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        metadata = {
          name = "operator";
          namespace = cfg.namespace;
        };
        rules = [
          {
            apiGroups = [""];
            resources = ["secrets" "serviceaccounts" "configmaps" "pods" "pods/log"];
            verbs = ["*"];
          }
          {
            apiGroups = ["apps"];
            resources = ["deployments" "statefulsets"];
            verbs = ["*"];
          }
        ];
      };

      # RoleBinding for namespace role
      "tailscale-operator-namespace-rolebinding" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        metadata = {
          name = "operator";
          namespace = cfg.namespace;
        };
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "operator";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "operator";
            namespace = cfg.namespace;
          }
        ];
      };

      # Operator Deployment
      "tailscale-operator-deployment" = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "operator";
          namespace = cfg.namespace;
          labels.app = "operator";
        };
        spec = {
          replicas = 1;
          selector.matchLabels.app = "operator";
          template = {
            metadata.labels.app = "operator";
            spec = {
              serviceAccountName = "operator";
              containers = [
                {
                  name = "operator";
                  image =
                    if cfg.image.tag != null
                    then "${cfg.image.repository}:${cfg.image.tag}"
                    else cfg.image.repository;
                  imagePullPolicy = "Always";
                  env = [
                    {
                      name = "OPERATOR_INITIAL_TAGS";
                      value = concatStringsSep "," cfg.defaultTags;
                    }
                    {
                      name = "OPERATOR_HOSTNAME";
                      value = "tailscale-operator";
                    }
                    {
                      name = "OPERATOR_SECRET";
                      value = "operator";
                    }
                    {
                      name = "OPERATOR_LOGGING";
                      value = "info";
                    }
                    {
                      name = "OPERATOR_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                    {
                      name = "CLIENT_ID_FILE";
                      value = "/oauth/client_id";
                    }
                    {
                      name = "CLIENT_SECRET_FILE";
                      value = "/oauth/client_secret";
                    }
                    {
                      name = "PROXY_IMAGE";
                      value =
                        if cfg.proxyImage.tag != null
                        then "${cfg.proxyImage.repository}:${cfg.proxyImage.tag}"
                        else cfg.proxyImage.repository;
                    }
                    {
                      name = "APISERVER_PROXY";
                      value = cfg.apiServerProxyConfig;
                    }
                    {
                      name = "PROXY_FIREWALL_MODE";
                      value = "auto";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "oauth";
                      mountPath = "/oauth";
                      readOnly = true;
                    }
                  ];
                  resources = {
                    requests = {
                      cpu = "100m";
                      memory = "128Mi";
                    };
                    limits = {
                      cpu = "500m";
                      memory = "512Mi";
                    };
                  };
                }
              ];
              volumes = [
                {
                  name = "oauth";
                  secret.secretName = "operator-oauth";
                }
              ];
            };
          };
        };
      };

      # IngressClass for Tailscale
      "tailscale-ingressclass" = {
        apiVersion = "networking.k8s.io/v1";
        kind = "IngressClass";
        metadata = {
          name = "tailscale";
          annotations = {
            "ingressclass.kubernetes.io/is-default-class" = "false";
          };
        };
        spec.controller = "tailscale.com/ts-ingress";
      };
    };

    # Sync OAuth credentials from sops to Kubernetes secret
    systemd.services.k3s-tailscale-oauth-sync = {
      description = "Sync Tailscale OAuth credentials to Kubernetes";
      after = ["k3s.service"];
      wants = ["k3s.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        kubectl = "${pkgs.kubectl}/bin/kubectl";
      in ''
        # Wait for k3s to be ready
        while ! ${kubectl} get namespace default >/dev/null 2>&1; do
          echo "Waiting for k3s to be ready..."
          sleep 5
        done

        # Ensure namespace exists
        ${kubectl} create namespace ${cfg.namespace} --dry-run=client -o yaml | ${kubectl} apply -f -

        # Read OAuth credentials from sops-decrypted files
        CLIENT_ID=$(cat ${config.sops.secrets.tailscale-k8s-oauth-client-id.path})
        CLIENT_SECRET=$(cat ${config.sops.secrets.tailscale-k8s-oauth-client-secret.path})

        # Create/update the secret
        ${kubectl} create secret generic operator-oauth \
          --namespace ${cfg.namespace} \
          --from-literal=client_id="$CLIENT_ID" \
          --from-literal=client_secret="$CLIENT_SECRET" \
          --dry-run=client -o yaml | ${kubectl} apply -f -

        echo "Tailscale OAuth credentials synced successfully"
      '';
    };
  };
}
