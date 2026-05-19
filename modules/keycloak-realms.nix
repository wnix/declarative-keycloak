{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.keycloak-realms;

  # Generate realm JSON from declarative configuration
  generateRealmJson = realmName: declarativeConfig: pkgs.writeText "${realmName}-realm.json" (builtins.toJSON {
    realm = realmName;
    displayName = declarativeConfig.displayName;
    displayNameHtml = if declarativeConfig.displayNameHtml != null 
                     then declarativeConfig.displayNameHtml 
                     else declarativeConfig.displayName;
    enabled = declarativeConfig.enabled;
    
    # Registration and auth settings
    registrationAllowed = declarativeConfig.registrationAllowed;
    resetPasswordAllowed = declarativeConfig.resetPasswordAllowed;
    rememberMe = true;
    verifyEmail = false;
    loginWithEmailAllowed = true;
    duplicateEmailsAllowed = false;
    editUsernameAllowed = false;
    bruteForceProtected = true;
    
    # SSL and security
    sslRequired = "external";
    
    # Session timeouts
    accessTokenLifespan = 300;
    ssoSessionIdleTimeout = 1800;
    ssoSessionMaxLifespan = 36000;
    
    # Browser security headers
    browserSecurityHeaders = {
      contentSecurityPolicy = "frame-src 'self'; frame-ancestors 'self'; object-src 'none';";
      xContentTypeOptions = "nosniff";
      xRobotsTag = "none";
      xFrameOptions = "SAMEORIGIN";
      xXSSProtection = "1; mode=block";
      strictTransportSecurity = "max-age=31536000; includeSubDomains";
    };
    
    # Roles
    roles = {
      realm = map (roleName: {
        name = roleName;
        description = "Role: ${roleName}";
        composite = false;
        clientRole = false;
        containerId = realmName;
      }) declarativeConfig.roles;
    };
    
    # Clients
    clients = mapAttrsToList (clientName: clientCfg: 
      let
        # Auto-generate redirect URIs with wildcards
        redirectUris = if clientCfg.redirectUris == [] then []
                       else map (uri: uri + "/*") clientCfg.redirectUris;
        
        # Auto-generate web origins from redirect URIs if not specified
        webOrigins = if clientCfg.webOrigins == [] && clientCfg.redirectUris != [] 
                     then (map (uri: uri) clientCfg.redirectUris) ++ ["+"]
                     else clientCfg.webOrigins;
      in {
        clientId = clientCfg.clientId;
        name = clientCfg.name;
        description = clientCfg.description;
        enabled = true;
        publicClient = clientCfg.publicClient;
        directAccessGrantsEnabled = clientCfg.directAccessGrantsEnabled;
        standardFlowEnabled = clientCfg.standardFlowEnabled;
        implicitFlowEnabled = false;
        serviceAccountsEnabled = false;
        inherit redirectUris webOrigins;
        protocol = "openid-connect";
        attributes = {
          "pkce.code.challenge.method" = "S256";
        };
        fullScopeAllowed = true;
      } // (if clientCfg.rootUrl != null then { rootUrl = clientCfg.rootUrl; } else {})
        // { baseUrl = clientCfg.baseUrl; }
    ) declarativeConfig.clients;
    
    # Default client scopes
    defaultDefaultClientScopes = [ "profile" "email" "roles" "web-origins" ];
    defaultOptionalClientScopes = [ "offline_access" "address" "phone" ];
  });

  # Get the realm file for a realm configuration
  getRealmFile = name: realmCfg:
    if realmCfg.declarative != null then
      generateRealmJson realmCfg.realmName realmCfg.declarative
    else if realmCfg.realmFile != null then
      realmCfg.realmFile
    else
      ../example-realms/default-realm.json;

  # Package the realm-manager script
  realm-manager = pkgs.buildNpmPackage {
    pname = "keycloak-realm-manager";
    version = "1.0.0";

    src = ../scripts;

    npmDepsHash = "sha256-/qlRUDLtxN7pKBwoEbZtQLNs6tlCWEeEFipxjNwQdbM=";

    # Don't run npm build, we just need the dependencies
    dontNpmBuild = true;

    installPhase = ''
      runHook preInstall
      
      mkdir -p $out/bin
      cp realm-manager.js $out/bin/realm-manager.js
      cp -r node_modules $out/bin/node_modules
      
      # Create wrapper script with proper node invocation
      cat > $out/bin/realm-manager <<EOF
      #!${pkgs.bash}/bin/bash
      exec ${pkgs.nodejs_20}/bin/node $out/bin/realm-manager.js "\$@"
      EOF
      
      chmod +x $out/bin/realm-manager
      
      runHook postInstall
    '';

    meta = {
      description = "Keycloak realm manager for declarative realm management";
      license = licenses.mit;
    };
  };

  # Helper to create a realm service configuration
  mkRealmService = name: realmCfg:
    let
      realmFile = getRealmFile name realmCfg;
      stateDir  = cfg.stateDir;

      # Script for mutableConfig = true (default): create once, never update
      execStartMutable = pkgs.writeShellScript "keycloak-realm-${name}-mutable" ''
        export KEYCLOAK_ADMIN_PASSWORD=$(cat $CREDENTIALS_DIRECTORY/admin-password)
        ${realm-manager}/bin/realm-manager create ${escapeShellArg realmCfg.realmName} ${realmFile}
        touch ${stateDir}/${name}.created
      '';

      # Script for mutableConfig = false: apply when Nix store path changed
      execStartImmutable = pkgs.writeShellScript "keycloak-realm-${name}-immutable" ''
        export KEYCLOAK_ADMIN_PASSWORD=$(cat $CREDENTIALS_DIRECTORY/admin-password)

        CURRENT_PATH=${realmFile}
        LAST_APPLIED_FILE=${stateDir}/${name}.last-applied-path

        if [ -f "$LAST_APPLIED_FILE" ] && [ "$(cat "$LAST_APPLIED_FILE")" = "$CURRENT_PATH" ]; then
          echo "Realm ${name}: config unchanged ($CURRENT_PATH), skipping."
          exit 0
        fi

        echo "Realm ${name}: config changed, applying..."
        ${realm-manager}/bin/realm-manager update-or-create ${escapeShellArg realmCfg.realmName} ${realmFile}
        echo "$CURRENT_PATH" > "$LAST_APPLIED_FILE"
        touch ${stateDir}/${name}.created
      '';
    in {
    description = "Create Keycloak realm: ${name}";
    after = [ "keycloak.service" ];
    wants = [ "keycloak.service" ];
    wantedBy = [ "multi-user.target" ];

    # For mutableConfig = true: only run if the marker file doesn't exist.
    # For mutableConfig = false: always run (change detection is inside the script).
    unitConfig = mkIf realmCfg.mutableConfig {
      ConditionPathExists = "!${stateDir}/${name}.created";
    };

    # Restart the service when the unit changes (i.e. when the Nix store path
    # of the realm JSON changes), so mutableConfig = false realms are re-applied
    # automatically on nixos-rebuild switch.
    restartIfChanged = !realmCfg.mutableConfig;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Exit code 2 means realm already exists, which is success for us
      SuccessExitStatus = "0 2";

      # Security hardening
      DynamicUser = false;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ stateDir ];

      # State directory for marker files
      StateDirectory = baseNameOf stateDir;

      # Load the admin password from file
      LoadCredential = [ "admin-password:${cfg.adminPasswordFile}" ];

      # Environment variables for realm-manager
      Environment = [
        "KEYCLOAK_URL=${cfg.keycloakUrl}"
        "KEYCLOAK_ADMIN_USER=${cfg.adminUser}"
      ];

      ExecStart = if realmCfg.mutableConfig then "${execStartMutable}" else "${execStartImmutable}";
    };
  };

  # Helper to create the manual replacement template service
  mkReplaceServiceTemplate = {
    description = "Replace Keycloak realm: %i";
    after = [ "keycloak.service" ];
    requires = [ "keycloak.service" ];

    serviceConfig = {
      Type = "oneshot";
      
      # Security hardening
      DynamicUser = false;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      
      # Load the admin password from file
      LoadCredential = [ "admin-password:${cfg.adminPasswordFile}" ];
      
      # Environment variables for realm-manager
      Environment = [
        "KEYCLOAK_URL=${cfg.keycloakUrl}"
        "KEYCLOAK_ADMIN_USER=${cfg.adminUser}"
      ];
      
      # The actual command - note: this is a template, %i will be replaced with realm name
      # We need to lookup the realm configuration from our cfg.realms
      ExecStart = let
        # Create a script that looks up the realm file based on the instance name
        lookupScript = pkgs.writeShellScript "keycloak-replace-realm" ''
          REALM_NAME="$1"
          
          export KEYCLOAK_ADMIN_PASSWORD=$(cat $CREDENTIALS_DIRECTORY/admin-password)
          
          # Look up realm file from configuration
          ${concatStringsSep "\n" (mapAttrsToList (name: realmCfg: ''
            if [ "$REALM_NAME" = "${name}" ]; then
              REALM_FILE="${getRealmFile name realmCfg}"
              ${realm-manager}/bin/realm-manager replace "${realmCfg.realmName}" "$REALM_FILE"
              exit $?
            fi
          '') cfg.realms)}
          
          echo "Error: Unknown realm: $REALM_NAME"
          exit 1
        '';
      in "${lookupScript} %i";
    };
  };

in {
  options.services.keycloak-realms = {
    enable = mkEnableOption "declarative Keycloak realm management";

    keycloakUrl = mkOption {
      type = types.str;
      default = "http://localhost:8080";
      description = mdDoc ''
        Keycloak base URL. This should point to the Keycloak server.
      '';
      example = "https://keycloak.example.com";
    };

    adminUser = mkOption {
      type = types.str;
      default = "admin";
      description = mdDoc ''
        Keycloak administrator username.
      '';
    };

    adminPasswordFile = mkOption {
      type = types.path;
      description = mdDoc ''
        Path to file containing the Keycloak administrator password.
        This file should contain only the password, with no trailing newline.
        
        When using sops-nix, this can be set to:
        `config.sops.secrets.keycloak-admin-password.path`
      '';
      example = "/run/secrets/keycloak-admin-password";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/keycloak-realms";
      description = mdDoc ''
        Directory to store state files (markers for created realms).
      '';
    };

    realms = mkOption {
      type = types.attrsOf (types.submodule ({ name, config, ... }: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = mdDoc ''
              Whether to enable this realm.
            '';
          };

          mutableConfig = mkOption {
            type = types.bool;
            default = false;
            description = mdDoc ''
              When false (default), the realm configuration is kept
              congruent with the Nix declaration: on every
              `nixos-rebuild switch`, the current Nix store path of the
              realm JSON is compared to the last applied path. If the
              config changed, the realm is automatically replaced.

              When true, the realm is created once and never
              automatically updated — imperative changes via the Keycloak
              UI or CLI are preserved (drift allowed). Manual replacement
              via `systemctl start keycloak-replace-realm@<name>` is
              still available.

              Mirrors the semantics of `users.mutableUsers`.
            '';
          };

          realmFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = mdDoc ''
              Path to the realm JSON file exported from Keycloak.
              If null and declarative is not configured, a default realm configuration will be used.
              
              You can export a realm from Keycloak using:
              - The Admin Console: Realm Settings → Action → Partial Export
              - The CLI: kcadm.sh get realms/REALM_NAME
              
              Note: This option is mutually exclusive with `declarative`.
            '';
            example = literalExpression "./realms/my-app-realm.json";
          };

          realmName = mkOption {
            type = types.str;
            default = name;
            description = mdDoc ''
              Name of the realm. By default, this is derived from the attribute name.
            '';
          };

          declarative = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                displayName = mkOption {
                  type = types.str;
                  default = config.realmName;
                  description = mdDoc "Display name for the realm";
                  example = "My Application";
                };

                displayNameHtml = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = mdDoc "HTML display name for the realm";
                  example = "<b>My</b> Application";
                };

                enabled = mkOption {
                  type = types.bool;
                  default = true;
                  description = mdDoc "Whether the realm is enabled";
                };

                registrationAllowed = mkOption {
                  type = types.bool;
                  default = true;
                  description = mdDoc "Allow user self-registration";
                };

                resetPasswordAllowed = mkOption {
                  type = types.bool;
                  default = true;
                  description = mdDoc "Allow password reset";
                };

                clients = mkOption {
                  type = types.attrsOf (types.submodule ({ name, ... }: {
                    options = {
                      clientId = mkOption {
                        type = types.str;
                        default = name;
                        description = mdDoc "Client ID (defaults to attribute name)";
                      };

                      name = mkOption {
                        type = types.str;
                        default = name;
                        description = mdDoc "Human-readable client name";
                      };

                      description = mkOption {
                        type = types.str;
                        default = "";
                        description = mdDoc "Client description";
                      };

                      publicClient = mkOption {
                        type = types.bool;
                        default = true;
                        description = mdDoc "Whether this is a public client (no secret required)";
                      };

                      redirectUris = mkOption {
                        type = types.listOf types.str;
                        default = [];
                        description = mdDoc ''
                          Base redirect URIs. Wildcards will be added automatically.
                          For example: `["http://localhost:3000"]` becomes `["http://localhost:3000/*"]`
                        '';
                        example = [ "http://localhost:3000" "https://app.example.com" ];
                      };

                      webOrigins = mkOption {
                        type = types.listOf types.str;
                        default = [];
                        description = mdDoc ''
                          CORS web origins. If empty, automatically derived from redirectUris.
                          Use "+" to allow all origins from redirect URIs.
                        '';
                        example = [ "http://localhost:3000" "https://app.example.com" ];
                      };

                      directAccessGrantsEnabled = mkOption {
                        type = types.bool;
                        default = true;
                        description = mdDoc "Enable direct access grants (Resource Owner Password Credentials)";
                      };

                      standardFlowEnabled = mkOption {
                        type = types.bool;
                        default = true;
                        description = mdDoc "Enable standard OpenID Connect flow";
                      };

                      rootUrl = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = mdDoc "Root URL for the client";
                      };

                      baseUrl = mkOption {
                        type = types.str;
                        default = "/";
                        description = mdDoc "Default URL to use when the auth server needs to redirect/link back to the client";
                      };
                    };
                  }));
                  default = {};
                  description = mdDoc "Client configurations";
                };

                roles = mkOption {
                  type = types.listOf types.str;
                  default = [ "user" ];
                  description = mdDoc "Simple list of realm role names";
                  example = [ "user" "admin" "manager" ];
                };
              };
            });
            default = null;
            description = mdDoc ''
              Declarative realm configuration. If set, generates a realm JSON from Nix configuration.
              This option is mutually exclusive with `realmFile`.
            '';
          };
        };
      }));
      default = {};
      description = mdDoc ''
        Declarative Keycloak realm configurations.
        
        Each realm will be created automatically on first boot if it doesn't exist.
        Existing realms will never be automatically updated.
        
        To manually replace a realm configuration, use:
        `systemctl start keycloak-replace-realm@REALM_NAME`
      '';
      example = literalExpression ''
        {
          myapp = {
            declarative = {
              displayName = "My Application";
              displayNameHtml = "<b>My</b> Application";
              clients.webapp = {
                name = "Web Application";
                description = "Main web application";
                redirectUris = [ "http://localhost:3000" "https://app.example.com" ];
                publicClient = true;
              };
              clients.api = {
                name = "API Backend";
                description = "Backend API";
                publicClient = false;
              };
              roles = [ "user" "admin" "manager" ];
            };
          };
          legacy = {
            realmFile = ./realms/legacy-realm.json;
          };
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    # Create systemd services for each enabled realm
    systemd.services = 
      # Per-realm automatic creation services
      (mapAttrs' (name: realmCfg: 
        nameValuePair "keycloak-realm-${name}" (mkRealmService name realmCfg)
      ) (filterAttrs (name: realmCfg: realmCfg.enable) cfg.realms))
      
      # Manual replacement template service
      // {
        "keycloak-replace-realm@" = mkReplaceServiceTemplate;
      };

    # Ensure the state directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root -"
    ];

    # Add realm-manager to system packages for manual use
    environment.systemPackages = [ realm-manager ];

    # Warnings for common misconfigurations
    warnings = 
      # Warn if keycloak service is not enabled
      (optional (!config.services.keycloak.enable) 
        "services.keycloak-realms is enabled but services.keycloak is not. Realm management requires a running Keycloak instance.")
      
      # Warn if no realms are configured
      ++ (optional (cfg.realms == {})
        "services.keycloak-realms is enabled but no realms are configured. Add realms to services.keycloak-realms.realms.");

    # Assertions for critical misconfigurations
    assertions = [
      {
        assertion = cfg.adminPasswordFile != "";
        message = "services.keycloak-realms.adminPasswordFile must be set to a path containing the Keycloak admin password.";
      }
    ] ++ (flatten (mapAttrsToList (name: realmCfg: [
      {
        assertion = !(realmCfg.realmFile != null && realmCfg.declarative != null);
        message = "Realm '${name}': realmFile and declarative options are mutually exclusive. Use only one.";
      }
    ]) cfg.realms));
  };
}

