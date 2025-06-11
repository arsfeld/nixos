# Example Supabase configuration for cloud host
# This file demonstrates how to use the Supabase module

{
  imports = [
    ../../modules/supabase
  ];

  # Enable the Supabase module
  constellation.supabase = {
    enable = true;
    defaultDomain = "rosenfeld.one";
    
    instances = {
      # Production instance
      prod = {
        enable = true;
        subdomain = "supabase";
        jwtSecret = "supabase-prod-jwt";
        anonKey = "supabase-prod-anon";
        serviceKey = "supabase-prod-service";
        databaseUrl = "supabase-prod-db";
        
        database = {
          name = "supabase_prod";
          user = "supabase_prod";
          createDatabase = true;
        };
        
        storage = {
          enable = true;
          bucket = "supabase-prod-storage";
        };
        
        services = {
          realtime = true;
          auth = true;
          restApi = true;
          storage = true;
        };
        
        logLevel = "info";
      };
      
      # Development instance
      dev = {
        enable = true;
        subdomain = "supabase-dev";
        jwtSecret = "supabase-dev-jwt";
        anonKey = "supabase-dev-anon";
        serviceKey = "supabase-dev-service";
        databaseUrl = "supabase-dev-db";
        
        database = {
          name = "supabase_dev";
          user = "supabase_dev";
          createDatabase = true;
        };
        
        storage = {
          enable = true;
          bucket = "supabase-dev-storage";
        };
        
        services = {
          realtime = true;
          auth = true;
          restApi = true;
          storage = true;
        };
        
        logLevel = "debug";
      };
    };
  };
  
  # Enable media gateway for routing
  media.gateway = {
    enable = true;
    domain = "rosenfeld.one";
    email = "admin@rosenfeld.one";
  };
  
  # Required media config for gateway integration
  media.config = {
    domain = "rosenfeld.one";
    email = "admin@rosenfeld.one";
  };
}

# To use this configuration:
# 1. Create secrets using: just supabase-create prod
# 2. Create secrets using: just supabase-create dev  
# 3. Add this configuration to your host
# 4. Deploy: just deploy cloud

# Accessing instances:
# Production: https://supabase.rosenfeld.one
# Development: https://supabase-dev.rosenfeld.one

# API endpoints:
# REST API: https://supabase.rosenfeld.one/rest/v1/
# Auth: https://supabase.rosenfeld.one/auth/v1/
# Storage: https://supabase.rosenfeld.one/storage/v1/
# Realtime: wss://supabase.rosenfeld.one/realtime/v1/websocket