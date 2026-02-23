{
  description = "Sutro relay - a minimal libp2p circuit relay server with AutoTLS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        relay = pkgs.buildGoModule {
          pname = "sutro-relay";
          version = "0.1.0";
          src = ./.;
          vendorHash = "sha256-pl4GzVBsYjqXnvqC07SmjJEqF8Xp7QlqD9Xpck91x6E=";
          env.CGO_ENABLED = 0;
          ldflags = [ "-s" "-w" ];
          meta = {
            description = "Minimal libp2p circuit relay server with AutoTLS";
            mainProgram = "relay";
          };
        };
      in
      {
        packages = {
          default = relay;
          docker = pkgs.dockerTools.buildImage {
            name = "sutro-relay";
            tag = "latest";
            copyToRoot = pkgs.buildEnv {
              name = "image-root";
              paths = [ relay pkgs.cacert ];
              pathsToLink = [ "/bin" "/etc/ssl" ];
            };
            config = {
              Entrypoint = [ "${relay}/bin/relay" ];
              ExposedPorts = {
                "4001/tcp" = {};
                "4001/udp" = {};
              };
              Volumes = {
                "/data" = {};
              };
              WorkingDir = "/data";
              Cmd = [
                "--identity" "/data/identity.key"
                "--certs" "/data/certs"
              ];
            };
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ go gopls ];
          shellHook = ''
            echo "sutro relay dev shell"
            echo "  go $(go version | cut -d' ' -f3)"
          '';
        };
      }
    );
}
