{
  self,
  lib,
  config,
}: 
with lib; let
  # Base port for auto-assignment
  basePort = 8000;
  
  # Helper to get domain
  getDomain = cfg: cfg.defaultDomain;
in {
  # Generate agenix secrets configuration
  generateSecrets = instances: 
    let
      enabledInstances = filterAttrs (name: cfg: cfg.enable) instances;
      secretsForInstance = name: instanceCfg: {
        ${instanceCfg.jwtSecret} = {
          file = "${self}/secrets/${instanceCfg.jwtSecret}.age";
          mode = "400";
          owner = "supabase-${name}";
        };
        ${instanceCfg.anonKey} = {
          file = "${self}/secrets/${instanceCfg.anonKey}.age";
          mode = "400"; 
          owner = "supabase-${name}";
        };
        ${instanceCfg.serviceKey} = {
          file = "${self}/secrets/${instanceCfg.serviceKey}.age";
          mode = "400";
          owner = "supabase-${name}";
        };
        ${instanceCfg.dbPassword} = {
          file = "${self}/secrets/${instanceCfg.dbPassword}.age";
          mode = "400";
          owner = "root";  # Database password needs to be readable by root for docker
        };
      };
    in
    lib.foldl' (acc: name: 
      acc // (secretsForInstance name enabledInstances.${name})
    ) {} (builtins.attrNames enabledInstances);
  
  
  # Generate systemd services  
  generateSystemdServices = instances: instanceUtils:
    mapAttrs' (name: instanceCfg:
      if instanceCfg.enable then {
        name = "supabase-${name}";
        value = instanceUtils.generateService name instanceCfg config;
      } else {}
    ) instances;
  
  # Generate gateway services
  generateGatewayServices = instances:
    mapAttrs' (name: instanceCfg:
      if instanceCfg.enable then {
        name = instanceCfg.subdomain;
        value = {
          enable = true;
          name = instanceCfg.subdomain;
          host = config.networking.hostName;
          port = if instanceCfg.port > 0 then instanceCfg.port else (basePort + (hashString "md5" name));
          settings = {
            cors = true;
            bypassAuth = true;  # Supabase handles its own auth
            funnel = false;
          };
        };
      } else {}
    ) instances;
  
  # Get all instance ports for firewall
  getInstancePorts = instances:
    map (instanceCfg: 
      if instanceCfg.port > 0 then instanceCfg.port else (basePort + (hashString "md5" instanceCfg.subdomain))
    ) (filter (instanceCfg: instanceCfg.enable) (attrValues instances));
  
  # Generate users and groups for instances
  generateUsers = instances:
    let
      enabledInstances = filterAttrs (name: cfg: cfg.enable) instances;
      users = mapAttrs' (name: instanceCfg: {
        name = "supabase-${name}";
        value = {
          isSystemUser = true;
          group = "supabase-${name}";
          extraGroups = [ "podman" ];
          home = "/var/lib/supabase-${name}";
          createHome = true;
        };
      }) enabledInstances;
      groups = mapAttrs' (name: instanceCfg: {
        name = "supabase-${name}";
        value = {};
      }) enabledInstances;
    in {
      inherit users groups;
    };
  
  # Hash string helper (simple implementation)
  hashString = type: s:
    let
      hash = builtins.hashString type s;
      # Convert first 6 chars of hash to number
      hexStr = builtins.substring 0 6 hash;
      # Simple hex to decimal conversion for port offset
      charToNum = c: 
        if c == "a" then 10 else if c == "b" then 11 else if c == "c" then 12 
        else if c == "d" then 13 else if c == "e" then 14 else if c == "f" then 15
        else if c >= "0" && c <= "9" then (builtins.fromJSON c) else 0;
    in
    builtins.foldl' (acc: c: acc + (charToNum c)) 0 (lib.stringToCharacters (builtins.toLower hexStr));
}