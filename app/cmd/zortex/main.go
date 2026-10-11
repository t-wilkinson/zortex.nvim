// Command zortex is the Go side of Zortex. For now it parses notes; the web
// app (search, folder browsing, rendering) will be added as subcommands.
//
//	zortex parse [-inline=false] [-pretty] FILE...   AST as JSON (one object per file)
//	zortex sections FILE...                          outline: level, line, type, text
//	zortex version
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  zortex parse [-inline=false] [-pretty] FILE...
  zortex sections FILE...
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
	case "version":
		fmt.Printf("zortex (ast version %d)\n", syntax.Version)
	default:
		usage()
	}
}
