{ config, pkgs, lib, ... }:

{
  # This is a NixOS container configuration for testing the keycloak-realms module.
  # 
  # To use this container:
  #
  # 1. Build the container:
  #    sudo nixos-container create keycloak-test --flake .#keycloak-test
  #
  # 2. Start the container:
  #    sudo nixos-container start keycloak-test
  #
  # 3. Check the status:
  #    sudo nixos-container status keycloak-test
  #
  # 4. View logs:
  #    sudo nixos-container run keycloak-test -- journalctl -u keycloak.service -f
  #    sudo nixos-container run keycloak-test -- journalctl -u keycloak-realm-default.service
  #    sudo nixos-container run keycloak-test -- journalctl -u keycloak-realm-demo.service
  #
  # 5. Access Keycloak:
  #    http://localhost:8080 (forwarded from container)
  #    Username: admin
  #    Password: admin (from test password file)
  #
  # 6. Test manual realm replacement:
  #    sudo nixos-container run keycloak-test -- systemctl start keycloak-replace-realm@demo
  #
  # 7. Stop the container:
  #    sudo nixos-container stop keycloak-test
  #
  # 8. Destroy the container:
  #    sudo nixos-container destroy keycloak-test

  # Enable container networking
  networking.hostName = "keycloak-test";
  networking.firewall.enable = false;

  # System state version
  system.stateVersion = "23.11";

  # PostgreSQL database for Keycloak
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_15;
    
    # Ensure PostgreSQL is ready before Keycloak starts
    ensureDatabases = [ "keycloak" ];
    ensureUsers = [{
      name = "keycloak";
      ensureDBOwnership = true;
    }];
    
    # Allow local connections
    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
  };

  # Keycloak service
  services.keycloak = {
    enable = true;
    
    settings = {
      # For test container, use full URL to allow dynamic backchannel
      hostname = "http://10.233.5.2:8080";
      hostname-strict = false;
      hostname-backchannel-dynamic = true;
      http-host = "0.0.0.0";
      http-port = 8080;
      http-enabled = true;
      proxy-headers = "xforwarded";
    };

    # Initial admin credentials
    initialAdminPassword = "admin";

    database = {
      type = "postgresql";
      host = "localhost";
      port = 5432;
      name = "keycloak";
      username = "keycloak";
      passwordFile = "/etc/keycloak-db-password";
      createLocally = false; # We're using ensureUsers/ensureDatabases instead
    };
  };

  # Create test password files
  # In production, these should use sops-nix or another secrets management solution
  environment.etc."keycloak-test-password" = {
    text = "admin";
    mode = "0400";
  };
  
  environment.etc."keycloak-db-password" = {
    text = "";
    mode = "0400";
  };

  # Enable the keycloak-realms module
  services.keycloak-realms = {
    enable = true;
    
    keycloakUrl = "http://localhost:8080";
    adminUser = "admin";
    adminPasswordFile = "/etc/keycloak-test-password";
    
    # Define test realms
    realms = {
      # Declarative realm with auto-generated patterns
      myapp = {
        enable = true;
        declarative = {
          displayName = "My Application";
          displayNameHtml = "<b>My</b> Application";
          registrationAllowed = true;
          resetPasswordAllowed = true;
          
          clients = {
            webapp = {
              name = "Web Application";
              description = "Main web application";
              publicClient = true;
              redirectUris = [ 
                "http://localhost:3000"
                "http://10.233.5.2:3000"
                "https://app.example.com"
              ];
              # webOrigins will be auto-generated from redirectUris
              directAccessGrantsEnabled = true;
              standardFlowEnabled = true;
              rootUrl = "http://localhost:3000";
            };
            
            api = {
              name = "API Backend";
              description = "Backend API service";
              publicClient = false;
              redirectUris = [];
              webOrigins = [];
              directAccessGrantsEnabled = false;
              standardFlowEnabled = false;
            };
            
            mobile = {
              name = "Mobile App";
              description = "Mobile application";
              publicClient = true;
              redirectUris = [ "myapp://oauth-callback" ];
              directAccessGrantsEnabled = true;
              standardFlowEnabled = true;
            };
          };
          
          roles = [ "user" "admin" "manager" "viewer" ];
        };
      };
      
      # Traditional realm using JSON file
      demo = {
        enable = true;
        realmFile = ../example-realms/demo-realm.json;
        realmName = "demo";
      };
    };
  };

  # Add some helpful packages for debugging
  environment.systemPackages = with pkgs; [
    curl
    jq
    postgresql
  ];

  # Ensure services start in the correct order
  systemd.services.keycloak = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
  };

  # Container-specific configuration
  boot.isContainer = true;
  
  # Allow container to be managed
  services.getty.autologinUser = lib.mkForce null;
}

