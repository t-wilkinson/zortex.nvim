{ buildGoModule, lib }:

# The Go side of Zortex (app/): for now the `zortex` CLI with the parser
# (`zortex parse`, `zortex sections`). No third-party Go dependencies.
buildGoModule {
  pname = "zortex";
  version = "0.1.0";
  src = lib.cleanSource ../app;
  vendorHash = null;
  subPackages = [ "cmd/zortex" ];
  env.CGO_ENABLED = "0";
  ldflags = [ "-s" "-w" ];

  # The conformance tests read ../tests/fixtures, which is outside src.
  doCheck = false;

  meta = {
    description = "Zortex notes: parser and (soon) web app";
    mainProgram = "zortex";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
