// Package web is the read-only web app over a notes folder: rendered notes
// with working links and backlinks, structural search, a file browser for
// every file in the folder (PDFs, images, media, text), tags and broken
// links. It is what `zortex serve` runs.
//
// The folder is read once at start and rescanned every Config.Poll (it is
// usually a Syncthing folder, so files change underneath). A rescan only
// re-parses notes whose modification time or size changed; when anything
// changed, the search index and the link graph are rebuilt in the background
// and swapped in, so requests never wait for a rebuild.
package web

import (
	"context"
	"embed"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"path"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

// Config of a Server.
type Config struct {
	Root    string        // notes folder
	Ext     string        // note extension (default ".zortex")
	Title   string        // site title (default "Zortex")
	Base    string        // URL path prefix when served below "/", e.g. "/notes"
	Poll    time.Duration // rescan interval (default 10s; <0: never)
	Special []string      // top-level notes shown in the file browser root and on the home page
	// CalendarURL is the notification server's dashboard (the Calendar tab in
	// the top bar, shared by both sites); empty hides the tab.
	CalendarURL string
	Logger      *log.Logger
}

// DefaultSpecial are the top-level notes listed by default (the plugin's
// well-known files).
var DefaultSpecial = []string{"calendar", "structure", "projects", "areas", "okr"}

// Server serves a notes folder. Create it with New.
type Server struct {
	cfg     Config
	ix      *notes.Index
	special map[string]bool
	pages   map[string]*template.Template
	static  http.Handler
	log     *log.Logger

	snap      atomic.Pointer[snapshot]
	rebuildMu sync.Mutex
}

// Backlink is a link in one note to (a line of) another.
type Backlink struct {
	From       string // source note
	Lnum       int    // line of the link
	Line       string // source line
	Breadcrumb string // section of the source line
	Def        string // link definition as written
	ToLnum     int    // target line
}

// Broken is a link that doesn't resolve.
type Broken struct {
	From string
	Lnum int
	Def  string
	Err  string
}

// snapshot is everything derived from the whole folder, rebuilt together.
type snapshot struct {
	search    *search.Index
	backlinks map[string][]Backlink // target note -> links to it
	broken    []Broken
	tags      []tagInfo // sorted by name
	recent    []string  // notes, most recently modified first
	notes     int
	links     int
	built     time.Time
	took      time.Duration
}

type tagInfo struct {
	Name  string
	Notes []string
}

// New reads the folder and builds the first snapshot.
func New(cfg Config) (*Server, error) {
	if cfg.Ext == "" {
		cfg.Ext = ".zortex"
	}
	if cfg.Title == "" {
		cfg.Title = "Zortex"
	}
	if cfg.Poll == 0 {
		cfg.Poll = 10 * time.Second
	}
	if cfg.Special == nil {
		cfg.Special = DefaultSpecial
	}
	cfg.Base = strings.TrimRight(cfg.Base, "/")
	if cfg.Base != "" && !strings.HasPrefix(cfg.Base, "/") {
		cfg.Base = "/" + cfg.Base
	}
	if cfg.Logger == nil {
		cfg.Logger = log.Default()
	}
	ix, err := notes.Open(cfg.Root, cfg.Ext)
	if err != nil {
		return nil, err
	}
	s := &Server{cfg: cfg, ix: ix, special: map[string]bool{}, log: cfg.Logger}
	for _, name := range cfg.Special {
		if name = strings.ToLower(strings.TrimSpace(name)); name != "" {
			s.special[name] = true
		}
	}
	if err := s.parseTemplates(); err != nil {
		return nil, err
	}
	sub, _ := fs.Sub(staticFS, "static")
	s.static = http.StripPrefix("/static/", http.FileServer(http.FS(sub)))
	ix.Scan()
	s.rebuild()
	return s, nil
}

// Run rescans the folder every Config.Poll until ctx is done.
func (s *Server) Run(ctx context.Context) {
	if s.cfg.Poll < 0 {
		return
	}
	t := time.NewTicker(s.cfg.Poll)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Refresh()
		}
	}
}

// Refresh rescans the folder now and rebuilds when something changed.
func (s *Server) Refresh() {
	if s.ix.Scan() {
		s.rebuild()
	}
}

func (s *Server) rebuild() {
	s.rebuildMu.Lock()
	defer s.rebuildMu.Unlock()
	start := time.Now()
	all := s.ix.All()
	snap := &snapshot{
		search:    search.BuildAll(s.ix),
		backlinks: map[string][]Backlink{},
		notes:     len(all),
	}
	tags := map[string]*tagInfo{}
	for _, rel := range all {
		doc := s.ix.Doc(rel)
		if doc == nil {
			continue
		}
		for _, tag := range doc.Header().Tags {
			key := strings.ToLower(tag)
			if tags[key] == nil {
				tags[key] = &tagInfo{Name: tag}
			}
			tags[key].Notes = append(tags[key].Notes, rel)
		}
		s.collectLinks(doc, snap)
	}
	for _, t := range tags {
		snap.tags = append(snap.tags, *t)
	}
	sort.Slice(snap.tags, func(i, j int) bool { return strings.ToLower(snap.tags[i].Name) < strings.ToLower(snap.tags[j].Name) })
	snap.recent = append([]string(nil), all...)
	sort.SliceStable(snap.recent, func(i, j int) bool {
		a, b := s.ix.Doc(snap.recent[i]), s.ix.Doc(snap.recent[j])
		return a != nil && b != nil && a.ModTime.After(b.ModTime)
	})
	snap.built, snap.took = time.Now(), time.Since(start)
	s.snap.Store(snap)
	// hand the previous snapshot's memory back now rather than at the next
	// GC cycle: on a small machine the peak matters more than the time
	runtime.GC()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	s.log.Printf("indexed %d notes, %d links (%d broken) in %s; heap %d MB", snap.notes, snap.links, len(snap.broken),
		snap.took.Round(time.Millisecond), ms.HeapInuse>>20)
}

// collectLinks resolves every link in doc (outside code) to its canonical
// target, as the plugin's link index does.
func (s *Server) collectLinks(doc *notes.Document, snap *snapshot) {
	for lnum := range doc.Lines {
		lnum++
		if doc.InCode(lnum) {
			continue
		}
		syntax.Walk(doc.Spans(lnum), func(sp *syntax.Span) {
			if sp.Type != "link" && sp.Type != "live_link" {
				return
			}
			if fileLike(sp.Definition) {
				return
			}
			snap.links++
			r, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: doc})
			if err != nil || r == nil {
				msg := "no match"
				if err != nil {
					msg = err.Error()
				}
				snap.broken = append(snap.broken, Broken{From: doc.Rel, Lnum: lnum, Def: sp.Definition, Err: msg})
				return
			}
			if r.Doc.Rel == doc.Rel {
				return // links within a note aren't backlinks
			}
			snap.backlinks[r.Doc.Rel] = append(snap.backlinks[r.Doc.Rel], Backlink{
				From:       doc.Rel,
				Lnum:       lnum,
				Line:       doc.Lines[lnum-1],
				Breadcrumb: doc.NodeAt(lnum).Breadcrumb(" › "),
				Def:        sp.Definition,
				ToLnum:     r.Lnum,
			})
		})
	}
}

func (s *Server) current() *snapshot { return s.snap.Load() }

// =============================================================================
// Routing
// =============================================================================

// Handler is the app's HTTP handler (mount it at Config.Base).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleHome)
	mux.HandleFunc("GET /n/{rel...}", s.handleNote)
	mux.HandleFunc("GET /f/{rel...}", s.handleFiles)
	mux.HandleFunc("GET /raw/{rel...}", s.handleRaw)
	mux.HandleFunc("GET /search", s.handleSearch)
	mux.HandleFunc("GET /link", s.handleLink)
	mux.HandleFunc("GET /tags", s.handleTags)
	mux.HandleFunc("GET /tag/{name}", s.handleTag)
	mux.HandleFunc("GET /broken", s.handleBroken)
	mux.HandleFunc("GET /api/search", s.apiSearch)
	mux.HandleFunc("GET /api/resolve", s.apiResolve)
	mux.HandleFunc("GET /api/backlinks", s.apiBacklinks)
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.Handle("GET /static/", s.cacheStatic(s.static))
	var h http.Handler = mux
	if base := s.cfg.Base; base != "" {
		strip := http.StripPrefix(base, mux)
		h = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// "/notes" -> "/notes/" (the mux alone would redirect to "/",
			// outside the prefix)
			if r.URL.Path == base {
				target := base + "/"
				if r.URL.RawQuery != "" {
					target += "?" + r.URL.RawQuery
				}
				http.Redirect(w, r, target, http.StatusMovedPermanently)
				return
			}
			strip.ServeHTTP(w, r)
		})
	}
	return securityHeaders(h)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hd := w.Header()
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("Referrer-Policy", "same-origin")
		h.ServeHTTP(w, r)
	})
}

func (s *Server) cacheStatic(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=3600")
		h.ServeHTTP(w, r)
	})
}

// url is an app path ("/n/x.zortex") with the base prefix.
func (s *Server) url(p string) string { return s.cfg.Base + p }

// noteURL links to a note, optionally at a line.
func (s *Server) noteURL(rel string, lnum int) string {
	u := s.url("/n/" + escapePath(rel))
	if lnum > 0 {
		u += "#L" + itoa(lnum)
	}
	return u
}

// fileURL links to the file viewer (folders: the listing).
func (s *Server) fileURL(rel string) string { return s.url("/f/" + escapePath(rel)) }

func (s *Server) rawURL(rel string) string { return s.url("/raw/" + escapePath(rel)) }

// isNote reports whether rel names a note (by extension).
func (s *Server) isNote(rel string) bool { return strings.HasSuffix(rel, s.cfg.Ext) }

// isSpecial reports whether a top-level note is one of Config.Special.
func (s *Server) isSpecial(rel string) bool {
	if strings.Contains(rel, "/") || !s.isNote(rel) {
		return false
	}
	return s.special[strings.ToLower(strings.TrimSuffix(rel, s.cfg.Ext))]
}

// cleanRel normalizes a request path to a rel path ("" for the root); ok is
// false for paths that try to leave the folder.
func cleanRel(p string) (string, bool) {
	p = strings.TrimPrefix(p, "/")
	if p == "" {
		return "", true
	}
	c := path.Clean("/" + p)[1:]
	if c != p && c+"/" != p {
		return "", false
	}
	for _, part := range strings.Split(c, "/") {
		if part == ".." || strings.HasPrefix(part, ".") {
			return "", false
		}
	}
	return c, true
}
