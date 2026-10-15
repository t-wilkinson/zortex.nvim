// Command zortex is the Go side of Zortex: the parser, link resolver and
// structural search over a notes folder, without Neovim, and the web app
// (`zortex serve`): the notes (read-only), the calendar and its ntfy
// notifications, and the pomodoro clock shared with Neovim.
//
//	zortex parse [-inline=false] [-pretty] FILE...      AST as JSON (one object per file)
//	zortex sections FILE...                             outline: level, line, type, text
//	zortex resolve [-dir D] [-from REL] LINK...         rel:lnum:col for each target
//	zortex search [-dir D] [-mode M] [-n N] PROMPT...   ranked sections, then lines
//	zortex serve [-dir D] [-addr A] [-base P] [-data D] ...   the web app: notes, calendar, pomodoro (see -h)
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
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/alerts"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
	"github.com/t-wilkinson/zortex.nvim/app/web"
)

// version is set at build time: -ldflags "-X main.version=v0.1.0"
var version = "dev"

// loopback: addr listens on localhost only.
func loopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  zortex parse [-inline=false] [-pretty] FILE...
  zortex sections FILE...
  zortex resolve [-dir DIR] [-from REL] LINK...
  zortex search [-dir DIR] [-mode section|article] [-n N] PROMPT...
  zortex serve [-dir DIR] [-addr HOST:PORT] [-base /PREFIX] [-title T] [-poll D] [-resources pdf,png,...]
               [-data DIR] [-ntfy-url URL] [-ntfy-topic T] [-ntfy-token TOKEN] [-api-key KEY] [-writable]
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
	poll := fs.Duration("poll", 3*time.Second, "how often to rescan the folder (negative: never)")
	resources := fs.String("resources", os.Getenv("ZORTEX_RESOURCES"), "extensions tracked as resources for backlinks and the unlinked list, e.g. pdf,epub,png (default: documents, books, images, media) ($ZORTEX_RESOURCES)")
	dataDefault := os.Getenv("ZORTEX_DATA_DIR")
	if dataDefault == "" {
		dataDefault = os.Getenv("STATE_DIRECTORY") // systemd StateDirectory=
	}
	data := fs.String("data", dataDefault, "state folder for notifications and the pomodoro clock; empty: read-only, no /notify or pomodoro ($ZORTEX_DATA_DIR, $STATE_DIRECTORY)")
	ntfyURL := fs.String("ntfy-url", os.Getenv("NTFY_SERVER_URL"), "ntfy server that delivers notifications ($NTFY_SERVER_URL)")
	ntfyTopic := fs.String("ntfy-topic", os.Getenv("NTFY_TOPIC"), "ntfy topic ($NTFY_TOPIC)")
	ntfyToken := fs.String("ntfy-token", os.Getenv("NTFY_AUTH_TOKEN"), "ntfy access token ($NTFY_AUTH_TOKEN)")
	ntfyTokenFile := fs.String("ntfy-token-file", os.Getenv("NTFY_AUTH_TOKEN_FILE"), "file holding the ntfy access token ($NTFY_AUTH_TOKEN_FILE)")
	apiKey := fs.String("api-key", os.Getenv("ZORTEX_API_KEY"), "if set, /notify and /pending require it in X-API-Key ($ZORTEX_API_KEY)")
	sendEvery := fs.Duration("send-interval", 20*time.Second, "how often due notifications are sent")
	authFile := fs.String("auth-file", os.Getenv("ZORTEX_AUTH_FILE"), "file of user:password lines: a login (HTTP basic auth) for every page; use it over HTTPS ($ZORTEX_AUTH_FILE, or ZORTEX_AUTH=user:password)")
	writable := fs.Bool("writable", os.Getenv("ZORTEX_WRITABLE") == "1" || os.Getenv("ZORTEX_WRITABLE") == "true", "let the web app edit notes: toggle tasks, edit, add and remove lines, add to inbox.zortex ($ZORTEX_WRITABLE=1)")
	htmlScripts := fs.Bool("html-scripts", os.Getenv("ZORTEX_HTML_SCRIPTS") == "1" || os.Getenv("ZORTEX_HTML_SCRIPTS") == "true", "let HTML files in the notes folder run JavaScript, sandboxed away from the site ($ZORTEX_HTML_SCRIPTS=1)")
	_ = fs.Parse(args)
	if v := os.Getenv("ZORTEX_POLL"); v != "" && !flagSet(fs, "poll") {
		if d, err := time.ParseDuration(v); err == nil {
			*poll = d
		}
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	token := *ntfyToken
	if *ntfyTokenFile != "" {
		raw, err := os.ReadFile(*ntfyTokenFile)
		if err != nil {
			logger.Fatal(err)
		}
		token = strings.TrimSpace(string(raw))
	}
	ntfy := &alerts.Ntfy{URL: *ntfyURL, Topic: *ntfyTopic, Token: token}
	if *data != "" && !ntfy.Enabled() {
		logger.Printf("ntfy is not configured: notifications are kept but not sent")
	}
	var accounts []web.Account
	var err error
	switch {
	case *authFile != "":
		if accounts, err = web.ReadAccounts(*authFile); err != nil {
			logger.Fatal(err)
		}
	case os.Getenv("ZORTEX_AUTH") != "":
		if accounts, err = web.ParseAccounts(os.Getenv("ZORTEX_AUTH")); err != nil || len(accounts) == 0 {
			logger.Fatalf("ZORTEX_AUTH: want user:password (%v)", err)
		}
	}
	if len(accounts) == 0 && !loopback(*addr) {
		logger.Printf("WARNING: listening on %s with no login: anyone who can reach it can read every note. Use -auth-file (or ZORTEX_AUTH=user:password), or keep it on 127.0.0.1 behind a proxy with a login.", *addr)
	}
	srv, err := web.New(web.Config{
		Root:         *dir,
		Title:        *title,
		Base:         *base,
		Poll:         *poll,
		DataDir:      *data,
		Ntfy:         ntfy,
		APIKey:       *apiKey,
		SendInterval: *sendEvery,
		Writable:     *writable,
		HTMLScripts:  *htmlScripts,
		ResourceExts: func() []string {
			if *resources == "" {
				return nil
			}
			return strings.Split(*resources, ",")
		}(),
		Accounts: accounts,
		Logger:   logger,
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
		fmt.Printf("zortex %s (ast version %d)\n", version, syntax.Version)
	default:
		usage()
	}
}
