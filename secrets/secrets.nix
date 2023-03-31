let
  arsfeld = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
  users = [arsfeld];

  storage = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILOJScEgldmHPqi7SqSl8GpKncVv5k7DXh2HGdnajIeQ root@storage";
  micro = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA6dDFoQv53Bb3vF0G2Kqna/O/bEr4o7lKkJL28+EIGK root@nixos-micro";
  systems = [storage micro];
in {
  "cloudflare.age".publicKeys = users ++ systems;
  "keycloak-pass.age".publicKeys = users ++ systems;
  "smtp_password.age".publicKeys = users ++ systems;
}
