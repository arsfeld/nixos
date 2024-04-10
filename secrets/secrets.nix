let
  arsfeld = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
  users = [arsfeld];

  storage = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILOJScEgldmHPqi7SqSl8GpKncVv5k7DXh2HGdnajIeQ root@storage";
  micro = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA6dDFoQv53Bb3vF0G2Kqna/O/bEr4o7lKkJL28+EIGK root@nixos-micro";
  cloud = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH51UBt4enqaDYdbEaBD1I1ef+wZGFmkjv68Mv4bnVWA root@dev";
  systems = [storage micro cloud];
in {
  "cloudflare.age".publicKeys = users ++ systems;
  "keycloak-pass.age".publicKeys = users ++ systems;
  "smtp_password.age".publicKeys = users ++ systems;
  "rclone-idrive.age".publicKeys = users ++ systems;
  "restic-password.age".publicKeys = users ++ systems;
  "restic-rest-cloud.age".publicKeys = users ++ [cloud];
  "restic-rest-micro.age".publicKeys = users ++ [micro];
  "transmission-openvpn-pia.age".publicKeys = users ++ [storage];
  "lldap-env.age".publicKeys = users ++ [cloud];
  "dex-clients-tailscale-secret.age".publicKeys = users ++ [cloud];
  "authelia-secrets.age".publicKeys = users ++ [cloud];
  "hetzner.age".publicKeys = users ++ systems;
  "borg-passkey.age".publicKeys = users ++ systems;
  "tailscale-key.age".publicKeys = users ++ systems;
  "attic-server.age".publicKeys = users ++ [cloud];
  "attic-token.age".publicKeys = users ++ systems;
  "attic-netrc.age".publicKeys = users ++ systems;
  "github-runner-token.age".publicKeys = users ++ systems;
}
