{config, ...}: let
  port = 3000;
in {
  media.containers.ask = {
    image = "itzcrazykns1337/vane:slim-latest";
    listenPort = port;
    exposePort = port;
    configDir = "/home/vane/data";
    environment = {
      SEARXNG_API_URL = "http://host.containers.internal:8888";
    };
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];
    watchImage = true;
  };

  media.gateway.services.ask.exposeViaTailscale = true;
}
