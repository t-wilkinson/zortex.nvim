#!/usr/bin/env bash
# summarize_lua_plugin.sh — v2.2
# ------------------------------------------------------------
# Produce a **compact Markdown** synopsis of a Neovim Lua plugin.
#   • Prints the directory tree (or a `find` fallback)
#   • Extracts per‑file headers, module tables, functions & comments
#   • Skips ignored directories:  refactor-plan  old  (plus any via -x)
#   • Minimal whitespace; no redundant `--` prefixes
#   • Nested sub‑functions indented two spaces / Lua indent level
#
# USAGE
#   source summarize_lua_plugin.sh   # or chmod +x ./summarize_lua_plugin.sh
#   summarize_lua_plugin <root_dir> [-o output.md] [-x extra_ignore]
# ------------------------------------------------------------

summarize_lua_plugin() {
  local root_dir
  local outfile

  if [[ $# -eq 0 ]]; then
    root_dir=.
    outfile="summary.md"
  else
    root_dir="${1:-.}"
    shift || true

    outfile="/dev/stdout"
    local -a EXTRA_IGNORES=()
    while [[ $# -gt 0 ]]; do
      case $1 in
      -o | --output)
        outfile="$2"
        shift 2
        ;;
      -x | --extra)
        EXTRA_IGNORES+=("$2")
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      esac
    done
  fi

  # ── Ignore list ────────────────────────────────────────────
  local -a IGNORE_DIRS=("refactor-plan" "old" "${EXTRA_IGNORES[@]}")

  # Build *find* prune argument array (no eval needed)
  local -a PRUNE_ARGS=()
  for d in "${IGNORE_DIRS[@]}"; do
    PRUNE_ARGS+=(-path "*/$d/*" -o)
  done
  unset 'PRUNE_ARGS[-1]' # remove trailing -o

  # Regex for quick ignore‑path check inside loops
  local ignore_re="/($(
    IFS='|'
    echo "${IGNORE_DIRS[*]}"
  ))(/|$)"

  # temp file for assembling the final report
  local tmp
  tmp="$(mktemp)"

  # ── 1. Directory tree ─────────────────────────────────────
  {
    echo "# Project structure"
    echo
    echo '```txt'
    if command -v tree &>/dev/null; then
      local tree_ignore
      tree_ignore="$(
        IFS='|'
        echo "${IGNORE_DIRS[*]}"
      )"
      tree -I "$tree_ignore" --filesfirst "$root_dir"
    else
      # Fallback: rudimentary tree‑like listing with `find`
      find "$root_dir" \( "${PRUNE_ARGS[@]}" \) -prune -o -print |
        sed "s#^$root_dir##"
    fi
    echo '```'
    echo
  } >>"$tmp"

  # ── 2. Per‑file summaries ─────────────────────────────────
  while IFS= read -r -d '' file; do
    [[ "$file" =~ $ignore_re ]] && continue

    # Header (first comment line)
    local header
    header="$(grep -m1 '^--' "$file" | sed 's/^--[[:space:]]*//')"
    if [[ -n "$header" ]]; then
      echo "## $header" >>"$tmp"
    else
      echo "## ${file#$root_dir/}" >>"$tmp"
    fi
    echo '```lua' >>"$tmp"

    # Awk: emit definitions & comments respecting requested rules
    awk '
      function flush_comments() {
        if (cb != "") { print ""; printf "%s", cb; cb=""; }
      }
      function indent_prefix(spaces) {
        pref=""; for (i = 0; i < int(spaces/2); i++) pref = pref "  ";
        return pref;
      }
      {
        # Collect contiguous leading comment lines
        if ($0 ~ /^\s*--/) { cb = cb $0 "\n"; next }

        # Module‑table definitions (M.foo = { ... })
        if ($0 ~ /^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=[[:space:]]*{/) {
          flush_comments();
          gsub(/^\s+/, "", $0);   # trim leading spaces
          print $0; next;
        }

        # Function definitions (top‑level or nested)
        if ($0 ~ /^[[:space:]]*function[[:space:]]/) {
          indent = match($0, /[^ ]/) - 1;
          flush_comments();
          printf "%s%s\n", indent_prefix(indent), substr($0, indent+1);
          next;
        }

        cb="";   # reset if non‑comment & non‑definition
      }
    ' "$file" >>"$tmp"

    echo '```' >>"$tmp"
    echo >>"$tmp"
  done < <(find "$root_dir" \( "${PRUNE_ARGS[@]}" \) -prune -o -type f -name '*.lua' -print0)

  # ── 3. Emit ───────────────────────────────────────────────
  if [[ "$outfile" == "/dev/stdout" ]]; then
    cat "$tmp"
    rm -f "$tmp"
  else
    mv "$tmp" "$outfile"
    echo "📄 Summary written to $outfile"
  fi
}

# If executed directly, run with cli args.
[[ "${BASH_SOURCE[0]}" == "$0" ]] && summarize_lua_plugin "$@"
