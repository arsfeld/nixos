{pkgs, ...}: {
  services.netdata = {
    enable = true;

    configDir."stream.conf" = pkgs.writeText "stream.conf" ''
      [stream]
        enabled = yes
        destination = storage:19999
        api key = 387acf23-8aff-4934-bc3a-1c2950e9df58
    '';

    config = {
      global = {"memory mode" = "none";};
      web = {
        mode = "none";
        "accept a streaming request every seconds" = 0;
      };
    };
  };
}
