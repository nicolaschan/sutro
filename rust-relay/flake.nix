{
  description = "Sunset relay - a minimal libp2p circuit relay server with gossipsub (Rust)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default;

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        src = craneLib.cleanCargoSource ./.;

        commonArgs = {
          inherit src;
          strictDeps = true;
          nativeBuildInputs = with pkgs; [
            pkg-config
          ];
          buildInputs = with pkgs; [
            openssl
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        relay = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          meta = {
            description = "Minimal libp2p circuit relay server with gossipsub";
            mainProgram = "relay";
          };
        });
      in
      {
        packages = {
          default = relay;
          docker = pkgs.dockerTools.buildImage {
            name = "sunset-relay";
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
              ];
            };
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustToolchain
            rust-analyzer
            pkg-config
            openssl
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
          shellHook = ''
            echo "sunset relay (Rust) dev shell"
            echo "  rustc $(rustc --version | cut -d' ' -f2)"
            echo "  cargo $(cargo --version | cut -d' ' -f2)"
          '';
        };
      }
    );
}
