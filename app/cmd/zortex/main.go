// Command zortex is the Go side of Zortex: the parser, link resolver and
// structural search over a notes folder, without Neovim. The web app will be
// added as a subcommand.
//
//	zortex parse [-inline=false] [-pretty] FILE...      AST as JSON (one object per file)
//	zortex sections FILE...                             outline: level, line, type, text
//	zortex resolve [-dir D] [-from REL] LINK...         rel:lnum:col for each target
//	zortex search [-dir D] [-mode M] [-n N] PROMPT...   ranked sections, then lines
//	zortex version
//
// -dir defaults to $ZORTEX_NOTES_DIR, then the current folder.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  zortex parse [-inline=false] [-pretty] FILE...
  zortex sections FILE...
  zortex resolve [-dir DIR] [-from REL] LINK...
  zortex search [-dir DIR] [-mode section|article] [-n N] PROMPT...
  zortex version`)
	os.Exit(2)
}

func readNote(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return syntax.SplitLines(string(data)), nil
}

func defaultDir() string {
	if d := os.Getenv("ZORTEX_NOTES_DIR"); d != "" {
		return d
	}
	return "."
}

func openNotes(dir string) *notes.Index {
	ix, err := notes.Open(dir, ".zortex")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	return ix
}

func resolveCmd(args []string) {
	fs := flag.NewFlagSet("resolve", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "notes folder")
	from := fs.String("from", "", "note (rel path) local links resolve in")
	_ = fs.Parse(args)
	if fs.NArg() == 0 {
		usage()
	}
	ix := openNotes(*dir)
	var opts links.Options
	if *from != "" {
		if opts.From = ix.Doc(*from); opts.From == nil {
			fmt.Fprintf(os.Stderr, "can't read %s\n", *from)
			os.Exit(1)
		}
	}
	failed := false
	for _, link := range fs.Args() {
		results, err := links.Resolve(ix, link, opts)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", link, err)
			failed = true
		}
		for _, r := range results {
			fmt.Printf("%s:%d:%d\t%s\n", r.Doc.Rel, r.Lnum, r.Col, r.Doc.Lines[r.Lnum-1])
		}
	}
	if failed {
		os.Exit(1)
	}
}

func searchCmd(args []string) {
	fs := flag.NewFlagSet("search", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "notes folder")
	mode := fs.String("mode", "section", "section or article")
	n := fs.Int("n", 20, "results to show (0: all)")
	_ = fs.Parse(args)
	idx := search.BuildAll(openNotes(*dir))
	results := search.Query(idx, strings.Join(fs.Args(), " "), *mode)
	if *n > 0 && len(results) > *n {
		results = results[:*n]
	}
	for _, r := range results {
		if r.Type == "section" {
			fmt.Printf("%s:%d\t%d\t%s\n", r.Rel, r.Lnum, r.Score, r.Breadcrumb)
		} else {
			fmt.Printf("%s:%d\t\t%s\n", r.Rel, r.Lnum, strings.TrimSpace(r.Line))
		}
	}
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "parse":
		fs := flag.NewFlagSet("parse", flag.ExitOnError)
		inline := fs.Bool("inline", true, "include inline spans")
		pretty := fs.Bool("pretty", false, "indent the JSON")
		_ = fs.Parse(os.Args[2:])
		if fs.NArg() == 0 {
			usage()
		}
		enc := json.NewEncoder(os.Stdout)
		if *pretty {
			enc.SetIndent("", "  ")
		}
		for _, path := range fs.Args() {
			lines, err := readNote(path)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			if err := enc.Encode(syntax.Parse(lines, *inline)); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	case "sections":
		if len(os.Args) < 3 {
			usage()
		}
		for _, path := range os.Args[2:] {
			lines, err := readNote(path)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			for _, s := range syntax.Parse(lines, false).Sections {
				indent := s.Level
				if indent > 8 {
					indent = 8
				}
				fmt.Printf("%s:%d\t%s%s %s\n", path, s.Lnum, strings.Repeat("  ", indent), s.Type, s.Text)
			}
		}
	case "resolve":
		resolveCmd(os.Args[2:])
	case "search":
		searchCmd(os.Args[2:])
	case "version":
		fmt.Printf("zortex (ast version %d)\n", syntax.Version)
	default:
		usage()
	}
}
