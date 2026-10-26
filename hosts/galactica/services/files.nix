{
  config,
  pkgs,
  lib,
  ...
}: let
  vars = config.media.config;

  # Syncthing device ID of the Pixel 3 XL that forwards staged photos to Google
  # Photos. This is a fresh Syncthing install (2026-07-26); an older, now-stale
  # "Pixel 3 XL" device (SZQ2JJJ…) still exists in the GUI config attached to the
  # legacy `photosync` folder, and is not this one.
  pixelDeviceId = "AHQ2BZC-LKGTOWG-PGKTKBV-6INI2Z6-O4RFQ5Q-ZN32AX3-R6KDSF6-WRHPNAT";
in {
  media.services.syncthing = {port = 8384;};

  media.services.filebrowser = {
    # s6 init chowns /app and /config: CHOWN; files owned by media: DAC_OVERRIDE, FOWNER; s6-applyuidgid drops to PUID/PGID: SETUID, SETGID; the filebrowser binary carries file capabilities, so exec under no-new-privileges fails without NET_BIND_SERVICE.
    container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID" "NET_BIND_SERVICE"];
    port = 8080;
    image = "filebrowser/filebrowser:s6";
    container = {
      exposePort = 38080;
      configDir = null;
      volumes = [
        "${vars.dataDir}/files:/srv"
        "${vars.configDir}/filebrowser/filebrowser.db:/database/filebrowser.db"
        "${vars.configDir}/filebrowser/settings.json:/config/settings.json"
      ];
    };
  };

  users.users.syncthing.extraGroups = ["media"];

  services.minio = {
    enable = false;
    dataDir = ["${vars.dataDir}/files/minio"];
  };

  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
    group = "media";

    # Every other folder and device on this host was created through the GUI.
    # Both of these default to true, which would DELETE anything Nix does not
    # declare — five folders (default, photos, photosync, and two more) and six
    # devices. Keep the declarative config strictly additive.
    overrideFolders = false;
    overrideDevices = false;

    settings = {
      devices.pixel3xl = {
        id = pixelDeviceId;
        name = "Pixel 3 XL (photo stage)";
        # galactica and the Pixel sit behind different routers that both use
        # 192.168.18.0/24, so there is no route between the sites and relaying is
        # the only fallback. Tailscale gives a direct path; keep `dynamic` after
        # it so discovery still works if the tailnet is down.
        addresses = ["tcp://pixel-3-xl.bat-boa.ts.net:22000" "dynamic"];
      };

      # sendonly here plus receiveonly on the phone means no deletion can travel
      # backwards into the staging directory — and nothing can reach Immich from
      # there anyway, since staged files are only hardlinks and reflinks.
      folders.pixel-photo-stage = {
        id = "pixel-photo-stage";
        label = "Pixel Photo Stage";
        path = config.constellation.immichPixelSync.stagingDirectory;
        type = "sendonly";
        devices = ["pixel3xl"];
      };
    };
  };

  services.webdav-server-rs = {
    enable = true;
    settings = {
      server.listen = ["0.0.0.0:4918" "[::]:4918"];
      accounts = {
        auth-type = "htpasswd.default";
        acct-type = "unix";
      };
      htpasswd.default = {
        htpasswd = pkgs.writeText "htpasswd" "arosenfeld:$2y$10$vVSREtogLxRBBRcKKcwNq.0mJTMeoQlKUnzI7Lmf4N7I.o7JKI/4u";
      };
      location = [
        {
          route = ["/public/*path"];
          directory = "/mnt/data/files";
          handler = "filesystem";
          methods = ["webdav-ro"];
          autoindex = true;
          auth = "false";
        }
        {
          route = ["/photosync/*path"];
          directory = "/mnt/data/files/PhotoSync";
          handler = "filesystem";
          methods = ["webdav-rw"];
          autoindex = true;
          auth = "true";
          setuid = true;
        }
      ];
    };
  };

  services.tsnsrv.services.webdav = {
    toURL = "http://127.0.0.1:4918";
    funnel = false;
  };
}
