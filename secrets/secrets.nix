let
  arsfeld = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
  users = [arsfeld];

  storage = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILOJScEgldmHPqi7SqSl8GpKncVv5k7DXh2HGdnajIeQ root@storage";
  cloud = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH51UBt4enqaDYdbEaBD1I1ef+wZGFmkjv68Mv4bnVWA root@dev";
  raspi3 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDgLgYS1DyvdxHbwa4p94Tnu6pbqksrtP7DmsagVOAfI root@raspi3";
  r2s = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1YUqHzxqtu512agJVUBNbTOWOad9/k0REig4RjEhdN root@nixos";
  router = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA8n1XWNmEvEHAMxqAljnkFkfMZrOYeZ16BYtnzG9fop root@router";
  cottage = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXEJms65pl6Fikoz3c6NG9p574RTWgJR7oJ3mmtMrok root@cottage";
  raider = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7ayPDvZPe5h8rWjmRn2GMCRaMvE4Lhxxd2JjhJFai3 root@raider";
  g14 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJzzvpNcM8z3tBKOmt/OZ11hGSkroo8EvDECaFmGuQoI root@nixos";
  systems = [storage cloud raspi3 r2s router cottage raider g14];
in {
  "authelia-secrets.age".publicKeys = users ++ [cloud];
  "bitmagnet-env.age".publicKeys = users ++ [storage];
  "borg-passkey.age".publicKeys = users ++ systems;
  "cloudflare.age".publicKeys = users ++ systems;
  "dex-clients-tailscale-secret.age".publicKeys = users ++ [cloud];
  "dex-clients-qui-secret.age".publicKeys = users ++ [cloud];
  "github-runner-token.age".publicKeys = users ++ systems;
  "forgejo-runner-token.age".publicKeys = users ++ [cloud];
  "gluetun-pia.age".publicKeys = users ++ systems;
  "homepage-env.age".publicKeys = users ++ systems;
  "lldap-env.age".publicKeys = users ++ [cloud];
  "lldap-password.age".publicKeys = users ++ [cloud];
  "qbittorrent-pia.age".publicKeys = users ++ [storage];
  "rclone-idrive.age".publicKeys = users ++ systems;
  "restic-password.age".publicKeys = users ++ systems;
  "restic-rest-cloud.age".publicKeys = users ++ [cloud];
  "restic-truenas.age".publicKeys = users ++ systems;
  "idrive-env.age".publicKeys = users ++ systems;
  "smtp_password.age".publicKeys = users ++ systems;
  "tailscale-key.age".publicKeys = users ++ systems;
  "tailscale-env.age".publicKeys = users ++ [storage cloud];
  "transmission-openvpn-pia.age".publicKeys = users ++ [storage];
  "ntfy-env.age".publicKeys = users ++ [cloud];
  "finance-tracker-env.age".publicKeys = users ++ [storage];
  "ghost-session-secret.age".publicKeys = users ++ [cloud];
  "ghost-smtp-env.age".publicKeys = users ++ [cloud];
  "ghost-session-env.age".publicKeys = users ++ [cloud];
  "romm-env.age".publicKeys = users ++ [storage];
  "plausible-secret-key.age".publicKeys = users ++ [cloud];
  "plausible-smtp-password.age".publicKeys = users ++ [cloud];
  "google-api-key.age".publicKeys = users ++ systems;
  "keycloak-pass.age".publicKeys = users ++ [cloud];

  # Garage S3-compatible storage (replaces MinIO)
  "garage-rpc-secret.age".publicKeys = users ++ [cottage];
  "garage-admin-token.age".publicKeys = users ++ [cottage];
  "plausible-admin-password.age".publicKeys = users ++ [cloud];
  "restic-rest-auth.age".publicKeys = users ++ systems;
  "restic-rest-micro.age".publicKeys = users ++ [cottage];
  "restic-cottage-minio.age".publicKeys = users ++ systems;

  # Planka secrets
  "planka-db-password.age".publicKeys = users ++ [cloud];
  "planka-secret-key.age".publicKeys = users ++ [cloud];

  # Siyuan secrets
  "siyuan-auth-code.age".publicKeys = users ++ [cloud];

  # Ohdio secrets
  "ohdio-env.age".publicKeys = users ++ [storage];

  # Qui OIDC secrets
  "qui-oidc-env.age".publicKeys = users ++ [storage];

  # Immich OIDC secrets
  "immich-oidc-secret.age".publicKeys = users ++ [storage];

  # Forgejo OIDC secrets
  "forgejo-oidc-secret.age".publicKeys = users ++ [storage];

  # OpenArchiver secrets
  "openarchiver-env.age".publicKeys = users ++ [storage];

  # MediaManager secrets
  "mediamanager-env.age".publicKeys = users ++ [storage];

  # Mydia secrets
  "mydia-env.age".publicKeys = users ++ [storage];

  # AirVPN secrets
  "airvpn-wireguard.age".publicKeys = users ++ [storage];
  "airvpn-env.age".publicKeys = users ++ [storage]; # Environment variables format for gluetun
  "transmission-openvpn-airvpn.age".publicKeys = users ++ [storage];

  # Tailscale exit node auth key (requires pre-approved exit node capability)
  "tailscale-exit-key.age".publicKeys = users ++ [storage];

  # Attic binary cache secrets
  "attic-credentials.age".publicKeys = users ++ [storage];
  "attic-server-token.age".publicKeys = users ++ [storage];
  "harmonia-cache-key.age".publicKeys = users ++ [raider];

  # Stash secrets
  "stash-jwt-secret.age".publicKeys = users ++ [raider];
  "stash-session-secret.age".publicKeys = users ++ [raider];
  "stash-password.age".publicKeys = users ++ [raider];

  # Hetzner Storage Box SSH key (for restic backup before ZFS migration)
  "hetzner-storagebox-ssh-key.age".publicKeys = users ++ [storage];

  # GitHub notifications
  "github-token.age".publicKeys = users ++ [raider storage];
}
