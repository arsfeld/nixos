{config, ...}: let
  port = 3000;
in {
  media.containers.ask = {
    image = "itzcrazykns1337/vane:latest";
    listenPort = port;
    exposePort = port;
    configDir = "/home/vane/data";
    watchImage = true;
    environment = {
      SEARXNG_API_URL = "http://host.containers.internal:8888";
    };
  };

  media.gateway.services.ask.exposeViaTailscale = true;
}
