{ pkgs, ... }:

let
  # Define python environment with Flask
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      flask
      werkzeug
    ]
  );

in
pkgs.stdenv.mkDerivation {
  pname = "zortex-server";
  version = "1.0.0";

  src = ../deployment;

  buildInputs = [
    pythonEnv
    pkgs.makeWrapper
  ];

  installPhase = ''
    mkdir -p $out/bin
    mkdir -p $out/libexec

    # Install the server script
    cp server.py $out/libexec/server.py

    # Create an executable wrapper for the server
    makeWrapper ${pythonEnv}/bin/python $out/bin/zortex-server \
      --add-flags "$out/libexec/server.py" \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.sqlite ]} 

    # Install the sender script
    cp send.sh $out/libexec/send.sh
    chmod +x $out/libexec/send.sh

    # Wrap the sender script with dependencies (sqlite3, curl, date)
    makeWrapper $out/libexec/send.sh $out/bin/zortex-sender \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.sqlite
          pkgs.curl
          pkgs.coreutils
        ]
      }
  '';

  meta = with pkgs.lib; {
    description = "Zortex Notification Server and Sender";
    license = licenses.mit; # Adjust as needed
    platforms = platforms.linux;
  };
}
