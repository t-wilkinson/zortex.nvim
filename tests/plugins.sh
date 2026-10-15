#!/bin/sh
# tests/plugins.sh [DIR] - the plugins the integration tests run against, at
# pinned versions, plus the fzf binary (DIR/bin). Then:
#
#   ZORTEX_TEST_PLUGINS=DIR nvim --headless -u NONE -l tests/run.lua
set -eu
dir=${1:-.tests/plugins}
mkdir -p "$dir/bin"

clone() { # name repo ref
	if [ ! -d "$dir/$1/.git" ]; then
		git clone --quiet --filter=blob:none "https://github.com/$2" "$dir/$1"
	fi
	git -C "$dir/$1" -c advice.detachedHead=false checkout --quiet "$3"
}

clone plenary.nvim nvim-lua/plenary.nvim v0.1.4
clone telescope.nvim nvim-telescope/telescope.nvim v0.2.2
clone snacks.nvim folke/snacks.nvim v2.31.0
clone fzf-lua ibhagwan/fzf-lua 3868dcc78d2c2766c9510ab18b6d3815071b389e
clone blink.cmp Saghen/blink.cmp v1.10.2

fzf=0.74.5
if [ ! -x "$dir/bin/fzf" ]; then
	curl -fsSL "https://github.com/junegunn/fzf/releases/download/v$fzf/fzf-$fzf-linux_amd64.tar.gz" | tar -xz -C "$dir/bin"
fi
echo "plugins in $dir"
