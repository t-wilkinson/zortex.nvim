#!/usr/bin/env bash
# Preview script for fzf. Replaces \f with \n and pretty prints with bat

ext=$1
body=$2
tr '\f' '\n' <<<"$body" | bat --color=always --plain --language md
