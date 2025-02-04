{...}: let
  # Generate a stable port number from a string (service name)
  # Uses SHA-256 hash to generate a number between 1024-65535
  nameToPort = name: let
    # Get SHA-256 hash of name and take first 8 chars
    hash = builtins.substring 0 6 (builtins.hashString "sha256" name);
    # Convert hex to decimal (base 16)
    decimal = (builtins.fromTOML "a = 0x${hash}").a;
    # Scale to port range (1024-65535)
    portRange = 65535 - 1024;
    # Implement modulo using division and multiplication
    remainder = decimal - (portRange * (decimal / portRange));
    port = 1024 + remainder;
  in
    port;

  # Helper function to process a set and replace null values with generated ports
  processServices = serviceSet:
    builtins.mapAttrs (
      name: value:
        if value == null
        then nameToPort name
        else value
    )
    serviceSet;
in rec {
  cloud = processServices {
    auth = null;
    dex = null;
    dns = null;
    ghost = 2368;
    invidious = null;
    metube = null;
    ntfy = null;
    search = null;
    users = null;
    vault = 8000;
    whoogle = 5000;
    yarr = 7070;
  };
  storage = processServices {
    bazarr = 6767;
    beszel = 8090;
    bitmagnet = 3333;
    code = 3434;
    duplicati = 8200;
    fileflows = 19200;
    filerun = 6000;
    filestash = 8334;
    flaresolverr = 8191;
    filebrowser = 38080;
    gitea = 3001;
    grafana = 3010;
    grocy = 9283;
    hass = 8123;
    headphones = 8787;
    home = 8085;
    immich = 15777;
    jackett = 9117;
    jellyfin = 8096;
    jf = 3831;
    lidarr = 8686;
    komga = null;
    netdata = 19999;
    nzbhydra2 = 5076;
    ollama-api = 11434;
    ollama = 30198;
    overseer = 5055;
    photoprism = 2342;
    photos = 2342;
    pinchflat = 8945;
    plex = 32400;
    prowlarr = 9696;
    qbittorrent = 8999;
    radarr = 7878;
    remotely = 5000;
    resilio = 9000;
    restic = 8000;
    romm = 8998;
    sabnzbd = 8080;
    scrutiny = 9998;
    seafile = 8082;
    sonarr = 8989;
    speedtest = 8765;
    stash = 9999;
    stirling = 9284;
    syncthing = 8384;
    tautulli = 8181;
    threadfin = 34400;
    transmission = 9091;
    whisparr = 6969;
    www = 8085;
  };

  ports = cloud // storage;
}
