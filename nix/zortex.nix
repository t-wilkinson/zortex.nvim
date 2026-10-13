{ buildGoModule, lib }:

# The Go side of Zortex (app/): the `zortex` binary, with the parser, link
# resolver and search on the command line and the notes web app
# (`zortex serve`, services.zortex.web). No third-party Go dependencies;
# templates and static files are embedded.
buildGoModule rec {
  pname = "zortex";
  version = "0.1.0";
  # app/ plus what its tests read: ../tests/fixtures (the conformance
  # fixtures the Lua side generates) and ../doc/example (every link in it
  # must resolve).
  src = lib.cleanSourceWith {
    src = lib.cleanSource ../.;
    filter = path: type:
      let rel = lib.removePrefix (toString ../. + "/") (toString path);
      in
      rel == "app"
      || lib.hasPrefix "app/" rel
      || rel == "tests"
      || lib.hasPrefix "tests/fixtures" rel
      || rel == "doc"
      || lib.hasPrefix "doc/example" rel;
  };
  modRoot = "app";
  vendorHash = null;
  env.CGO_ENABLED = "0";
  ldflags = [ "-s" "-w" "-X main.version=v${version}" ];

  # go test ./... (the parser, edits and links against the Lua fixtures)
  doCheck = true;
  checkFlags = [ "-skip=TestFiresOnItsOwn" ]; # wall-clock timing; flaky on busy builders

  meta = {
    description = "Zortex: parser, link resolver, search and the web app (notes, calendar, notifications, pomodoro)";
    mainProgram = "zortex";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
