# Declarative Keycloak Realm Management for NixOS

A NixOS module for declarative management of Keycloak realms with a focus on safety, idempotency, and clean integration with secrets management.

## Features

- **Declarative by Default**: Realm configuration is kept congruent with Nix — changes are applied automatically on `nixos-rebuild switch`
- **Safe Change Detection**: Uses Nix store path hashing to detect changes with zero runtime overhead — no diff, no API polling
- **Opt-in Drift**: Set `mutableConfig = true` on a realm to allow imperative changes via the Keycloak UI or CLI to persist
- **Manual Realm Replacement**: Explicit mechanism for replacing realm configurations when needed (e.g., promoting from dev to prod)
- **Clean JavaScript Implementation**: Modern Node.js code using the official Keycloak Admin Client
- **Secrets Integration**: Designed to work seamlessly with sops-nix and systemd credential loading
- **Comprehensive Testing**: Includes a test container for validation

## Quick Start

### As a Flake Input

Add to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    declarative-keycloak.url = "path:/path/to/declarative-keycloak";
  };

  outputs = { self, nixpkgs, declarative-keycloak }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        declarative-keycloak.nixosModules.default
      ];
    };
  };
}
```

### Basic Configuration

In your `configuration.nix`:

```nix
{ config, pkgs, ... }:

{
  # Enable Keycloak
  services.keycloak = {
    enable = true;
    settings = {
      hostname = "keycloak.example.com";
      http-port = 8080;
    };
    database = {
      type = "postgresql";
      createLocally = true;
    };
    initialAdminPassword = "change-me"; # Use secrets in production!
  };

  # Enable declarative realm management
  services.keycloak-realms = {
    enable = true;
    keycloakUrl = "http://localhost:8080";
    adminUser = "admin";
    adminPasswordFile = "/path/to/password/file";

    realms = {
      myapp = {
        realmFile = ./realms/myapp-realm.json;
      };
    };
  };
}
```

## Configuration Options

### `services.keycloak-realms.enable`

Type: `boolean`

Default: `false`

Enable the declarative Keycloak realm management module.

### `services.keycloak-realms.keycloakUrl`

Type: `string`

Default: `"http://localhost:8080"`

The base URL of your Keycloak server.

### `services.keycloak-realms.adminUser`

Type: `string`

Default: `"admin"`

The Keycloak administrator username.

### `services.keycloak-realms.adminPasswordFile`

Type: `path`

**Required**

Path to a file containing the Keycloak administrator password. This file should contain only the password with no trailing newline.

When using sops-nix, set this to: `config.sops.secrets.keycloak-admin-password.path`

### `services.keycloak-realms.stateDir`

Type: `path`

Default: `"/var/lib/keycloak-realms"`

Directory to store state files (markers for created realms). These markers ensure idempotency.

### `services.keycloak-realms.realms.<name>`

Type: `attribute set`

Define your realms here. Each attribute name becomes a realm identifier.

#### `services.keycloak-realms.realms.<name>.enable`

Type: `boolean`

Default: `true`

Whether to enable this realm.

#### `services.keycloak-realms.realms.<name>.mutableConfig`

Type: `boolean`

Default: `false`

When `false` (default), the realm is kept congruent with the Nix declaration. On every `nixos-rebuild switch`, the module compares the current Nix store path of the realm JSON against the last applied path. If it changed, the realm is automatically replaced in Keycloak.

When `true`, the realm is created once and never automatically updated. Imperative changes via the Keycloak UI or CLI are preserved (drift allowed). Manual replacement via `systemctl start keycloak-replace-realm@<name>` is still available.

This mirrors the semantics of `users.mutableUsers`.

#### `services.keycloak-realms.realms.<name>.realmFile`

Type: `null or path`

Default: `null`

Path to the realm JSON file. If `null`, a default realm configuration will be used.

Export a realm from Keycloak using:
- Admin Console: Realm Settings → Action → Partial Export
- CLI: `kcadm.sh get realms/REALM_NAME`

#### `services.keycloak-realms.realms.<name>.realmName`

Type: `string`

Default: `<name>` (the attribute name)

Name of the realm. This must match the `"realm"` field in your realm JSON file.

## Usage Examples

### Declarative Realm Configuration (Recommended)

The easiest way to configure realms is using the declarative Nix configuration. This approach automatically generates realm JSON with sensible defaults:

```nix
services.keycloak-realms = {
  enable = true;
  adminPasswordFile = "/run/secrets/keycloak-admin";
  
  realms.myapp = {
    declarative = {
      displayName = "My Application";
      displayNameHtml = "<b>My</b> Application";
      
      clients = {
        webapp = {
          name = "Web Application";
          description = "Main web application";
          publicClient = true;
          redirectUris = [
            "http://localhost:3000"
            "https://app.example.com"
          ];
          # webOrigins auto-generated from redirectUris
        };
        
        api = {
          name = "Backend API";
          description = "API service";
          publicClient = false;
          redirectUris = [];
        };
      };
      
      roles = [ "user" "admin" "manager" ];
    };
  };
};
```

**Features of declarative configuration:**
- **Auto-generate redirect URI wildcards**: `"http://localhost:3000"` → `"http://localhost:3000/*"`
- **Auto-generate CORS origins**: Automatically derived from `redirectUris` + `"+"`
- **Type-safe configuration**: Nix validates your configuration at build time
- **Sensible defaults**: Security headers, session timeouts, etc.
- **Client defaults**: PKCE enabled, proper OIDC settings

### Multiple Realms (Mixed Declarative and File-based)

You can mix declarative and file-based realm configurations:

```nix
services.keycloak-realms = {
  enable = true;
  adminPasswordFile = "/run/secrets/keycloak-admin";
  
  realms = {
    # Declarative realm
    production = {
      declarative = {
        displayName = "Production";
        clients.webapp = {
          redirectUris = [ "https://app.example.com" ];
          publicClient = true;
        };
        roles = [ "user" "admin" ];
      };
    };
    
    # File-based realm (for complex configurations or imports)
    staging = {
      realmFile = ./realms/staging-realm.json;
      realmName = "staging";
    };
    
    # Use default realm
    development = {
      realmFile = null;
      realmName = "dev";
    };
  };
};
```

### Integration with sops-nix

```nix
{ config, ... }:

{
  # Configure sops
  sops.secrets.keycloak-admin-password = {
    sopsFile = ./secrets/keycloak.yaml;
    key = "keycloak/admin_password";
  };

  # Use the secret with keycloak-realms
  services.keycloak-realms = {
    enable = true;
    adminPasswordFile = config.sops.secrets.keycloak-admin-password.path;
    
    realms.myapp = {
      realmFile = ./realms/myapp-realm.json;
    };
  };
}
```

### Custom Keycloak URL

```nix
services.keycloak-realms = {
  enable = true;
  keycloakUrl = "https://keycloak.example.com";
  adminUser = "admin";
  adminPasswordFile = config.sops.secrets.keycloak-admin.path;
  
  realms.myapp = {
    realmFile = ./realms/myapp-realm.json;
  };
};
```

## Manual Realm Replacement

With `mutableConfig = true`, realms are never automatically updated. To manually replace a realm configuration (e.g., when promoting changes from dev to prod):

```bash
# Replace the 'myapp' realm
sudo systemctl start keycloak-replace-realm@myapp

# Check the status
sudo systemctl status keycloak-replace-realm@myapp

# View logs
sudo journalctl -u keycloak-replace-realm@myapp
```

**⚠️ Warning**: This will **delete and recreate** the realm, removing all users, sessions, and data!

## Exporting Realm Configurations

### From Keycloak Admin Console

1. Log in to Keycloak Admin Console
2. Select your realm
3. Navigate to: **Realm Settings** → **Action** → **Partial Export**
4. Select what to export (clients, roles, groups, etc.)
5. Click **Export**
6. Save the downloaded JSON file

### Using the CLI

```bash
# Export a specific realm
kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password admin

kcadm.sh get realms/my-realm > my-realm.json
```

### Important Notes

- Use **Partial Export** for complete realm configurations
- **Full Export** may include sensitive data - review before committing
- The `"realm"` field in the JSON must match your configuration
- Remove any dynamically generated IDs if you want portability

## How It Works

### Declarative mode (`mutableConfig = false`, default)

1. On every `nixos-rebuild switch`, the systemd service (`keycloak-realm-<name>.service`) activates
2. The service compares the current Nix store path of the realm JSON against the path stored in `/var/lib/keycloak-realms/<name>.last-applied-path`
3. If unchanged: logs "config unchanged, skipping" and exits immediately
4. If changed (or first run):
   - Waits for Keycloak to be ready
   - Connects to Keycloak Admin API
   - Replaces the realm if it exists, creates it if not
   - Writes the new store path to `<name>.last-applied-path`
   - Creates the `<name>.created` marker

The Nix store path itself encodes a content hash — it changes if and only if the realm JSON changes. No runtime hashing or diffing required.

### Mutable mode (`mutableConfig = true`)

1. On boot, the systemd service starts for each defined realm
2. The service checks if `/var/lib/keycloak-realms/<name>.created` exists
3. If the marker doesn't exist:
   - Waits for Keycloak to be ready
   - Creates the realm from the JSON file
   - Creates the marker file
4. If the marker exists, the service is skipped (systemd `ConditionPathExists`) — imperative changes are preserved

### Manual Replacement

1. You trigger the replacement: `systemctl start keycloak-replace-realm@<name>`
2. The template service looks up the realm configuration
3. Connects to Keycloak Admin API, deletes the existing realm, recreates it from the JSON file
4. The marker file is **not** used (always runs when triggered)

### Security

- Passwords are loaded via systemd's `LoadCredential` and passed through environment variables
- Services run with limited privileges (`NoNewPrivileges`, `ProtectSystem`, etc.)
- State directory has restricted permissions
- The realm-manager script validates inputs and has comprehensive error handling

## Testing with the Container

A complete test container is included:

```bash
# Navigate to the repository
cd /path/to/declarative-keycloak

# Create the container
sudo nixos-container create keycloak-test --flake .#keycloak-test

# Start the container
sudo nixos-container start keycloak-test

# Wait a minute for services to start, then access Keycloak
# Open: http://localhost:8080
# Username: admin
# Password: admin

# Check realm creation logs
sudo nixos-container run keycloak-test -- journalctl -u keycloak-realm-default.service
sudo nixos-container run keycloak-test -- journalctl -u keycloak-realm-demo.service

# Test manual replacement
sudo nixos-container run keycloak-test -- systemctl start keycloak-replace-realm@demo

# Stop the container
sudo nixos-container stop keycloak-test

# Destroy the container (when done testing)
sudo nixos-container destroy keycloak-test
```

## Troubleshooting

### Realm Not Created

Check the service logs:

```bash
journalctl -u keycloak-realm-<name>.service
```

Common issues:
- Keycloak not ready: The script waits up to 60 seconds
- Invalid JSON: Check your realm file syntax
- Wrong admin password: Verify `adminPasswordFile` contents
- Network issues: Ensure `keycloakUrl` is correct

### Manual Replacement Fails

```bash
journalctl -u keycloak-replace-realm@<name>.service
```

Common issues:
- Realm doesn't exist: The realm must exist to be replaced
- Realm in use: Active sessions might cause issues
- Permission denied: Check admin credentials

### Reset Everything

To force recreation of a realm (declarative mode, `mutableConfig = false`):

```bash
# Remove the state files so the service re-applies on next activation
sudo rm /var/lib/keycloak-realms/<name>.created
sudo rm /var/lib/keycloak-realms/<name>.last-applied-path

# Trigger immediately
sudo systemctl restart keycloak-realm-<name>.service
```

For mutable mode (`mutableConfig = true`):

```bash
sudo systemctl stop keycloak-realm-<name>.service
sudo rm /var/lib/keycloak-realms/<name>.created
sudo systemctl start keycloak-realm-<name>.service
```

### Debug Mode

Run the realm-manager script manually:

```bash
# Check if a realm exists
realm-manager check my-realm

# Create a realm (only if it doesn't exist)
KEYCLOAK_ADMIN_PASSWORD=admin \
realm-manager create my-realm /path/to/realm.json

# Replace a realm (must already exist)
KEYCLOAK_ADMIN_PASSWORD=admin \
realm-manager replace my-realm /path/to/realm.json

# Replace if exists, create if not (used internally by mutableConfig = false)
KEYCLOAK_ADMIN_PASSWORD=admin \
realm-manager update-or-create my-realm /path/to/realm.json
```

## Development

### Project Structure

```
.
├── flake.nix                    # Main flake definition
├── modules/
│   └── keycloak-realms.nix     # NixOS module
├── scripts/
│   ├── realm-manager.js        # JavaScript implementation
│   ├── package.json            # NPM dependencies
│   └── package-lock.json       # NPM lock file
├── example-realms/
│   ├── default-realm.json      # Default realm config
│   └── demo-realm.json         # Demo realm config
├── containers/
│   └── keycloak-test.nix       # Test container
└── README.md                   # This file
```

### Development Shell

```bash
nix develop

# You now have Node.js and NPM available
node --version
npm --version
```

### Testing Changes

1. Modify the code
2. Rebuild the container:
   ```bash
   sudo nixos-container destroy keycloak-test
   sudo nixos-container create keycloak-test --flake .#keycloak-test
   sudo nixos-container start keycloak-test
   ```
3. Check the logs

## Realm JSON Structure

A minimal realm JSON must include:

```json
{
  "realm": "my-realm",
  "enabled": true,
  "displayName": "My Realm",
  "clients": [],
  "roles": {
    "realm": []
  }
}
```

You can include:
- Clients (applications)
- Roles and groups
- Identity providers
- Authentication flows
- Security policies
- Theme settings
- Email server configuration
- And much more...

Refer to the example realms in `example-realms/` for inspiration.

## Migration Guide

### From Manual Keycloak Management

If you already have realms in Keycloak and want to bring them under Nix management without recreating them:

1. Export your existing realms from Keycloak
2. Save them as JSON files in your NixOS configuration
3. Add the keycloak-realms module with `mutableConfig = true` on each realm:
   ```nix
   realms.myapp = {
     mutableConfig = true;
     realmFile = ./realms/myapp-realm.json;
   };
   ```
4. Apply the configuration — the module will skip creation (marker file absent) and create the marker
5. Once you're ready for fully declarative management, switch to `mutableConfig = false`

### To Another Server

1. Export realm from source server
2. Copy realm JSON to destination
3. Configure keycloak-realms with the realm
4. Let it auto-create on first boot, OR
5. Use manual replacement if realm already exists

## Contributing

Contributions are welcome! Areas for improvement:

- [ ] Dry-run mode for testing configurations
- [ ] Better validation of realm JSON files
- [ ] Integration tests
- [ ] More example realms
- [ ] CLI tool for common operations

## License

MIT License - see the source files for details.

## Credits

Built with:
- [Keycloak](https://www.keycloak.org/) - Identity and Access Management
- [@keycloak/keycloak-admin-client](https://www.npmjs.com/package/@keycloak/keycloak-admin-client) - Official Keycloak Admin Client
- [NixOS](https://nixos.org/) - Declarative Linux distribution
- [sops-nix](https://github.com/Mic92/sops-nix) - Secrets management (optional integration)

