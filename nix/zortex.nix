{ buildGoModule, lib }:

# The Go side of Zortex (app/): the `zortex` binary, with the parser, link
# resolver and search on the command line and the notes web app
# (`zortex serve`, services.zortex.web). No third-party Go dependencies;
# templates and static files are embedded.
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
    description = "Zortex notes: parser, link resolver, search and read-only web app";
    mainProgram = "zortex";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
