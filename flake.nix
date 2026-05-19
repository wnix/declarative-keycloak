{
  description = "Declarative Keycloak realm management for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Define the systems we support
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # NixOS module output
      nixosModules.keycloak-realms = import ./modules/keycloak-realms.nix;
      
      # Default module for convenience
      nixosModules.default = self.nixosModules.keycloak-realms;

      # Container configuration for testing
      nixosConfigurations.keycloak-test = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./containers/keycloak-test.nix
          self.nixosModules.keycloak-realms
        ];
      };

    } // flake-utils.lib.eachSystem systems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # Package the realm-manager script
        packages = {
          realm-manager = pkgs.buildNpmPackage {
            pname = "keycloak-realm-manager";
            version = "1.0.0";

            src = ./scripts;

            npmDepsHash = "sha256-/qlRUDLtxN7pKBwoEbZtQLNs6tlCWEeEFipxjNwQdbM=";

            # Don't run npm build, we just need the dependencies
            dontNpmBuild = true;

            installPhase = ''
              runHook preInstall
              
              mkdir -p $out/bin
              cp realm-manager.js $out/bin/realm-manager
              cp -r node_modules $out/bin/node_modules
              
              # Make the script executable and add node shebang
              chmod +x $out/bin/realm-manager
              
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Keycloak realm manager for declarative realm management";
              license = licenses.mit;
              maintainers = [ ];
            };
          };

          default = self.packages.${system}.realm-manager;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nodejs_20
            nodePackages.npm
          ];
          
          shellHook = ''
            echo "Declarative Keycloak Realm Management - Development Shell"
            echo "Node version: $(node --version)"
            echo "NPM version: $(npm --version)"
          '';
        };
      }
    );
}

