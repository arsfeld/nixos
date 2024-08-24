let
  arsfeld = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
  users = [arsfeld];

  storage = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILOJScEgldmHPqi7SqSl8GpKncVv5k7DXh2HGdnajIeQ root@storage";
  micro = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA6dDFoQv53Bb3vF0G2Kqna/O/bEr4o7lKkJL28+EIGK root@nixos-micro";
  cloud = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH51UBt4enqaDYdbEaBD1I1ef+wZGFmkjv68Mv4bnVWA root@dev";
  raider = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIODq88FlnK+Px/J6hNSPvpJEkrFFYf/oYUqCUBQ7+2cz root@nixos";
  raspi3 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDgLgYS1DyvdxHbwa4p94Tnu6pbqksrtP7DmsagVOAfI root@raspi3";
  core = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIApMMHFDPH4I3DZNf4s2M+/OGST+s5zt3184kq08AKVS root@core";
  g14 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGj9e4+iZNzP2hnCVwr48VOay0y/zzphvkrBtG2WoJi+ root@G14";
  systems = [storage micro cloud raspi3 core g14];
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
  "attic-netrc.age".publicKeys = users ++ systems ++ [raider];
  "github-runner-token.age".publicKeys = users ++ systems;
}
