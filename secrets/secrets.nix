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
  "lldap-env.age".publicKeys = users ++ [cloud];
  "authelia-jwt.age".publicKeys = users ++ [cloud];
  "authelia-storage-encryption-key.age".publicKeys = users ++ [cloud];
}
