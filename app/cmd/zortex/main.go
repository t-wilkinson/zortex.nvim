// Command zortex is the Go side of Zortex: the parser, link resolver and
// structural search over a notes folder, without Neovim, and the read-only
// web app (`zortex serve`).
//
//	zortex parse [-inline=false] [-pretty] FILE...      AST as JSON (one object per file)
//	zortex sections FILE...                             outline: level, line, type, text
//	zortex resolve [-dir D] [-from REL] LINK...         rel:lnum:col for each target
//	zortex search [-dir D] [-mode M] [-n N] PROMPT...   ranked sections, then lines
//	zortex serve [-dir D] [-addr A] [-base P] ...       the web app (see -h)
//	zortex version
//
// -dir defaults to $ZORTEX_NOTES_DIR, then the current folder.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
	"github.com/t-wilkinson/zortex.nvim/app/web"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  zortex parse [-inline=false] [-pretty] FILE...
  zortex sections FILE...
  zortex resolve [-dir DIR] [-from REL] LINK...
  zortex search [-dir DIR] [-mode section|article] [-n N] PROMPT...
  zortex serve [-dir DIR] [-addr HOST:PORT] [-base /PREFIX] [-title T] [-poll D] [-special a,b] [-calendar URL] [-resources pdf,png,...]
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

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func serveCmd(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "notes folder ($ZORTEX_NOTES_DIR)")
	addr := fs.String("addr", envOr("ZORTEX_ADDR", "127.0.0.1:8090"), "listen address ($ZORTEX_ADDR)")
	base := fs.String("base", os.Getenv("ZORTEX_BASE"), "URL prefix when proxied below /, e.g. /notes ($ZORTEX_BASE)")
	title := fs.String("title", envOr("ZORTEX_TITLE", "Zortex"), "site title ($ZORTEX_TITLE)")
	poll := fs.Duration("poll", 10*time.Second, "how often to rescan the folder (negative: never)")
	special := fs.String("special", envOr("ZORTEX_SPECIAL", strings.Join(web.DefaultSpecial, ",")), "top-level notes listed by default ($ZORTEX_SPECIAL)")
	resources := fs.String("resources", os.Getenv("ZORTEX_RESOURCES"), "extensions tracked as resources for backlinks and the unlinked list, e.g. pdf,epub,png (default: documents, books, images, media) ($ZORTEX_RESOURCES)")
	calendar := fs.String("calendar", os.Getenv("ZORTEX_CALENDAR_URL"), "URL of the notification server's calendar, shown as the Calendar tab ($ZORTEX_CALENDAR_URL)")
	_ = fs.Parse(args)
	if v := os.Getenv("ZORTEX_POLL"); v != "" && !flagSet(fs, "poll") {
		if d, err := time.ParseDuration(v); err == nil {
			*poll = d
		}
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	srv, err := web.New(web.Config{
		Root:        *dir,
		Title:       *title,
		Base:        *base,
		Poll:        *poll,
		Special:     strings.Split(*special, ","),
		CalendarURL: *calendar,
		ResourceExts: func() []string {
			if *resources == "" {
				return nil
			}
			return strings.Split(*resources, ",")
		}(),
		Logger: logger,
	})
	if err != nil {
		logger.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go srv.Run(ctx)

	hs := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hs.Shutdown(shutdown)
	}()
	logger.Printf("serving %s on http://%s%s/", *dir, *addr, strings.TrimRight(*base, "/"))
	if err := hs.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatal(err)
	}
}

func flagSet(fs *flag.FlagSet, name string) bool {
	set := false
	fs.Visit(func(f *flag.Flag) { set = set || f.Name == name })
	return set
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
	case "serve":
		serveCmd(os.Args[2:])
	case "version":
		fmt.Printf("zortex (ast version %d)\n", syntax.Version)
	default:
		usage()
	}
}
