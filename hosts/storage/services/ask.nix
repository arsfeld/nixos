{config, ...}: let
  port = 3000;
in {
  media.containers.ask = {
    image = "itzcrazykns1337/vane:latest";
    listenPort = port;
    exposePort = port;
    configDir = "/home/vane/data";
    watchImage = true;
  };

  media.gateway.services.ask.exposeViaTailscale = true;
}
