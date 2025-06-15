let
  arsfeld = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
  users = [arsfeld];

  storage = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILOJScEgldmHPqi7SqSl8GpKncVv5k7DXh2HGdnajIeQ root@storage";
  micro = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA6dDFoQv53Bb3vF0G2Kqna/O/bEr4o7lKkJL28+EIGK root@nixos-micro";
  cloud = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH51UBt4enqaDYdbEaBD1I1ef+wZGFmkjv68Mv4bnVWA root@dev";
  raider = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIODq88FlnK+Px/J6hNSPvpJEkrFFYf/oYUqCUBQ7+2cz root@nixos";
  raspi3 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDgLgYS1DyvdxHbwa4p94Tnu6pbqksrtP7DmsagVOAfI root@raspi3";
  core = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIApMMHFDPH4I3DZNf4s2M+/OGST+s5zt3184kq08AKVS root@core";
  g14 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMiYsUOYKV9yWD262A4b2X4x/umbw5HrCBkyNexctEgz root@G14";
  hpe = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBioA7Y9FOdvgXG7C4/UhH2R6kzK2eZn0P6T/90nwCQQ root@hpe";
  r2s = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1YUqHzxqtu512agJVUBNbTOWOad9/k0REig4RjEhdN root@nixos";
  systems = [storage micro cloud raspi3 core g14 hpe r2s];
in {
  "authelia-secrets.age".publicKeys = users ++ [cloud];
  "bitmagnet-env.age".publicKeys = users ++ [storage];
  "borg-passkey.age".publicKeys = users ++ systems;
  "cloudflare.age".publicKeys = users ++ systems;
  "dex-clients-tailscale-secret.age".publicKeys = users ++ [cloud];
  "github-runner-token.age".publicKeys = users ++ systems;
  "gluetun-pia.age".publicKeys = users ++ systems;
  "homepage-env.age".publicKeys = users ++ systems;
  "lldap-env.age".publicKeys = users ++ [cloud];
  "qbittorrent-pia.age".publicKeys = users ++ [storage];
  "rclone-idrive.age".publicKeys = users ++ systems;
  "restic-password.age".publicKeys = users ++ systems;
  "restic-rest-cloud.age".publicKeys = users ++ [cloud];
  "restic-rest-micro.age".publicKeys = users ++ [micro];
  "restic-truenas.age".publicKeys = users ++ systems;
  "idrive-env.age".publicKeys = users ++ systems;
  "smtp_password.age".publicKeys = users ++ systems;
  "tailscale-key.age".publicKeys = users ++ systems;
  "transmission-openvpn-pia.age".publicKeys = users ++ [storage];
  "ntfy-env.age".publicKeys = users ++ [cloud];
  "finance-tracker-env.age".publicKeys = users ++ [storage];
  "ghost-session-secret.age".publicKeys = users ++ [cloud];
  "ghost-smtp-env.age".publicKeys = users ++ [cloud];
  "ghost-session-env.age".publicKeys = users ++ [cloud];
  "romm-env.age".publicKeys = users ++ [storage];
  "supabase-finaro-env.age".publicKeys = users ++ [cloud];
}
