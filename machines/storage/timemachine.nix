{
  config,
  pkgs,
  ...
}: let
  timeMachineDir = "/mnt/data/backups/Time Machine";
  user = "timemachine";
in {
  services.netatalk = {
    enable = true;

    volumes = {
      "Bacon's House Time Machine" = {
        "time machine" = "yes";
        path = "${timeMachineDir}";
        "valid users" = "${user}";
      };
    };
  };

  users.extraUsers.timeMachine = {
    name = "${user}";
    group = "users";
  };
  systemd.services.timeMachineSetup = {
    description = "idempotent directory setup for ${user}'s time machine";
    requiredBy = ["netatalk.service"];
    script = ''
      mkdir -p "${timeMachineDir}"
       chown "${user}:users" "${timeMachineDir}"  # making these calls recursive is a switch
       chmod 0750 "${timeMachineDir}"           # away but probably computationally expensive
    '';
  };

  #networking.firewall.allowedTCPPorts = [ 548 636 ];
}
