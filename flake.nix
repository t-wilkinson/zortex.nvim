{
  description = "Zortex Notification Server Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # Package output: nix build .#default
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.callPackage ./nix/package.nix { };
        }
      );

      # NixOS Module output
      nixosModules.default = import ./nix/module.nix;

      # Dev shell for testing locally: nix develop
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              self.packages.${system}.default
              python3
              sqlite
              curl
              (python3.withPackages (
                ps: with ps; [
                  flask
                  werkzeug
                ]
              ))
            ];
            shellHook = ''
              export FLASK_PORT=5000
              export DATABASE_PATH="$HOME/.local/state/zortex/notifications.db"
              export NTFY_SERVER_URL="https://ntfy.home.lab"

              # Automatically create the data directory for local dev
              mkdir -p $(dirname $DATABASE_PATH)

              echo "Zortex dev environment ready."
              echo "Run 'python deployment/server.py' to start server."
              echo "Run './deployment/send.sh' to process queue."
            '';
          };
        }
      );
    };
}
