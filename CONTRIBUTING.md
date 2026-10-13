# Contributing

Issues and pull requests are welcome. The code is Lua (the Neovim plugin,
`lua/zortex`) and Go (the server, `app/`), and both read the same note
format, so most changes come with a test on each side.

## Running the tests

```sh
nvim --headless -u NONE -l tests/run.lua          # Lua; a filter: tests/run.lua links
go -C app test -race ./...                         # Go
gofmt -l app                                       # must print nothing
```

The Lua tests need nothing but Neovim 0.10+ (telescope is stubbed). CI runs
them on Neovim 0.10.4, stable and nightly, plus the Go tests, `go vet`,
`gofmt` and a Nix build.

## Generated files

Some files are written from the code; CI fails when they are out of date.
After changing the grammar, the link resolver, task edits or the actions:

```sh
nvim --headless -u NONE -l tests/gen_docs.lua    # README command table, doc/zortex.txt
nvim --headless -u NONE -l tests/gen_ast.lua     # tests/fixtures/ast: the parser's output
nvim --headless -u NONE -l tests/gen_links.lua   # tests/fixtures/{resolve,search}.json
nvim --headless -u NONE -l tests/gen_edits.lua   # tests/fixtures/edits.json
```

The fixtures are the contract between the two sides: the Lua parser,
resolver, search and task edits write them, and the Go packages
(`app/syntax`, `app/links`, `app/search`, `app/edit`) are tested against
them. Change the Lua side, regenerate, then make the Go side pass.

`doc/Syntax.md` is checked too: every example in its tables must be a line
of `tests/fixtures/syntax` that the parser classifies as the table says.

## Where things are

[doc/Architecture.md](doc/Architecture.md) explains the Lua layers and the
rules modules share; [app/README.md](app/README.md) the server's packages.

## Releasing

1. Move the changes under a version heading in `CHANGELOG.md` and set
   `version` in `nix/zortex.nix`.
2. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`.
3. The release workflow builds `zortex` for Linux and macOS (amd64, arm64),
   creates the GitHub release with that changelog section, and pushes the
   image to `ghcr.io/<owner>/zortex` (`latest`, `0.1`, `0.1.0`).
