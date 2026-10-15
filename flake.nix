{
  description = "Zortex: Neovim plugin and its server (notes web app, calendar, notifications, pomodoro)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
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
          # Go CLI and server (app/cmd/zortex: `zortex serve`)
          default = pkgs.callPackage ./nix/zortex.nix { };
          zortex = pkgs.callPackage ./nix/zortex.nix { };
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
              go
              curl
              neovim
            ];
            shellHook = ''
              export ZORTEX_DATA_DIR="$HOME/.local/state/zortex"
              mkdir -p "$ZORTEX_DATA_DIR"
              echo "Zortex dev environment ready."
              echo "  go -C app run ./cmd/zortex serve -dir ~/zortex       # http://127.0.0.1:8090/"
              echo "  go -C app test ./...   ·   nvim --headless -u NONE -l tests/run.lua"
            '';
          };
        }
      );
    };
}
