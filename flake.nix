{
  description = "Zortex Notification Service";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.python3Packages.buildPythonApplication {
            pname = "zortex";
            version = "1.0.0";
            format = "other";

            src = ./.;

            propagatedBuildInputs = with pkgs.python3Packages; [
              flask
              werkzeug
            ];

            installPhase = ''
              mkdir -p $out/bin $out/share/zortex
              cp server.py $out/share/zortex/server.py

              makeWrapper ${pkgs.python3Packages.python.interpreter} $out/bin/zortex-server \
                --add-flags "$out/share/zortex/server.py" \
                --prefix PYTHONPATH : "$PYTHONPATH"
            '';
          };
        }
      );

      nixosModules.default = import ./module.nix { inherit self; };
    };
}
