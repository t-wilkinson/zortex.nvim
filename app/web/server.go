// Package web is the read-only web app over a notes folder: rendered notes
// with working links and backlinks, structural search, a file browser for
// every file in the folder (PDFs, images, media, text), tags and broken
// links. It is what `zortex serve` runs.
//
// The folder is read once at start, watched for changes (inotify, on
// Linux) and rescanned every Config.Poll as well (it is usually a Syncthing
// folder, so files change underneath). A rescan only
// re-parses notes whose modification time or size changed; when anything
// changed, the search index and the link graph are rebuilt in the background
// and swapped in, so requests never wait for a rebuild.
package web

import (
	"context"
	"embed"
	"github.com/t-wilkinson/zortex.nvim/app/feeds"
	"hash/fnv"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"path"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/alerts"
	"github.com/t-wilkinson/zortex.nvim/app/clocks"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/pomodoro"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
	"github.com/t-wilkinson/zortex.nvim/app/tracker"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

// Config of a Server.
type Config struct {
	Root  string        // notes folder
	Ext   string        // note extension (default ".zortex")
	Title string        // site title (default "Zortex")
	Base  string        // URL path prefix when served below "/", e.g. "/notes"
	Poll  time.Duration // rescan interval (default 3s; <0: never)
	// NoWatch: don't watch the folder for changes (Linux inotify), only
	// rescan every Poll. Watching shows a synced edit within about a second.
	NoWatch bool
	// DataDir holds the server's own state: scheduled notifications and the
	// pomodoro clock. Empty: read-only mode (no scheduled notifications, no pomodoro).
	DataDir string
	// Ntfy delivers due notifications and pomodoro phase changes; nil or
	// unconfigured: notifications are kept (and shown) but not sent.
	Ntfy *alerts.Ntfy
	// APIKey, when set, is required (X-API-Key header) by the endpoints
	// Neovim uses: /api/notifications and its sync, clear and test.
	APIKey string
	// SendInterval: how often due notifications are sent (default 20s).
	SendInterval time.Duration
	// Calendar is the calendar note (default "calendar" + Ext).
	Calendar string
	// Writable lets the web app edit notes: toggle tasks, edit, add and
	// remove lines, add to the inbox (see edit.go). Off: read-only.
	Writable bool
	// ResourceExts: extensions of the files tracked as resources (backlinks,
	// unlinked list); nil: DefaultResourceExts.
	ResourceExts []string
	// Accounts, when set, is a login (HTTP basic auth) for every page and
	// endpoint except /healthz; see auth.go. Empty: no login (keep the
	// server on localhost behind a proxy that has one).
	Accounts []Account
	// HTMLScripts lets HTML files in the notes folder run JavaScript in the
	// file viewer and at /raw. They still run sandboxed, in an opaque origin:
	// no access to this site's pages, cookies or login, and POSTs they send
	// are refused (see htmlScriptsGuard). Off: HTML is shown without script.
	HTMLScripts bool
	// Feeds: calendars fetched into z/feeds/<name>.zortex (app/feeds);
	// they need the notes folder writable by the server.
	Feeds []feeds.Feed
	// ShareToken lets a calendar app subscribe to GET /calendar.ics (the
	// calendar's @share lines) without the login: ?token=<ShareToken>.
	// Empty: /calendar.ics needs the login like every page.
	ShareToken string
	// NoXP turns XP off: no XP panel on the home page, no season tiers,
	// /api/xp answers {"available": false}. Neovim's xp.enabled = false is
	// the same on its side.
	NoXP   bool
	Logger *log.Logger
}

// Server serves a notes folder. Create it with New.
type Server struct {
	cfg     Config
	ix      *notes.Index
	resExts map[string]bool
	pages   map[string]*template.Template
	static  http.Handler
	log     *log.Logger

	snap      atomic.Pointer[snapshot]
	rebuildMu sync.Mutex

	alerts *alerts.Store    // nil without DataDir
	sender *alerts.Sender   // nil without DataDir
	pomo   *pomodoro.Clock  // nil without DataDir
	clocks *clocks.Clocks   // timers, alarms, stopwatch; nil without DataDir
	track  *tracker.Tracker // time on tasks; nil without DataDir (used with Writable)
	// what is opened from search (DataDir/search_history.json, never the
	// notes' .z/); nil without DataDir
	history *search.History
	// pages kept on the home page (DataDir/bookmarks.json); nil without DataDir
	bookmarks *bookmarkStore
	xp        xpCache     // XP summary published by Neovim
	fired     firedAlerts // the alerts raised lately, for Neovim (GET /api/alerts)

	editMu      sync.Mutex    // one edit at a time
	inboxSent   sentIDs       // inbox captures by id, so a resend adds once (edit.go)
	completions completionLog // tasks completed on the web, until Neovim counts them
	copies      copyCache     // calendar copies of tasks by @id (mirrors.go)

	events        eventHub  // live updates for open pages (/api/events)
	opens         openWaits // /api/open requests waiting for a tab (open.go)
	xpFileMu      sync.Mutex
	xpFileSeen    time.Time // mtime of .z/xp_summary.json at the last rescan
	xpFileChecked bool
	// .z/syntax.json (syntaxfile.go): last seen mtime
	syntaxMu      sync.Mutex
	syntaxSeen    time.Time
	syntaxChecked bool
}

// Backlink is a link in one note (or Markdown file) to a line of another
// note, or to a resource file.
type Backlink struct {
	From       string // source note or file
	FromNote   bool   // From is a note (else a Markdown file)
	Lnum       int    // line of the link
	Line       string // source line
	Breadcrumb string // section of the source line
	Def        string // link definition as written
	ToLnum     int    // target line (notes)
}

// Broken is a link that doesn't resolve.
type Broken struct {
	From     string
	FromNote bool
	Lnum     int
	Def      string
	Err      string
}

// snapshot is everything derived from the whole folder, rebuilt together.
type snapshot struct {
	search    *search.Index
	backlinks map[string][]Backlink // target note -> links to it
	inner     map[string][]Backlink // note -> its links to its own lines
	broken    []Broken
	tags      []tagInfo // sorted by name
	recent    []string  // notes, most recently modified first
	notes     int
	links     int
	built     time.Time
	took      time.Duration

	resources     []resource
	fileBacklinks map[string][]Backlink // resource -> links to it
	unlinked      map[string]int        // folder -> unlinked resources inside it
	names         map[string][]string   // lower-cased file name -> resources
	fingerprint   uint64                // of the resources and Markdown files

	structure structureInfo        // notes not linked from the Structure note
	forward   map[string][]outLink // note -> its links to other notes, by line
	nav       navMenu              // the top bar's Files menu (navmenu.go)
}

// outLink is a link from a note to another note.
type outLink struct {
	Lnum int
	To   string
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
		cfg.Poll = 3 * time.Second
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
	s := &Server{cfg: cfg, ix: ix, resExts: map[string]bool{}, log: cfg.Logger}
	if cfg.ResourceExts == nil {
		cfg.ResourceExts = DefaultResourceExts
	}
	for _, e := range cfg.ResourceExts {
		if e = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(e), ".")); e != "" {
			s.resExts[e] = true
		}
	}
	if cfg.Calendar == "" {
		cfg.Calendar = "calendar" + cfg.Ext
		s.cfg.Calendar = cfg.Calendar
	}
	if err := s.parseTemplates(); err != nil {
		return nil, err
	}
	if cfg.DataDir != "" {
		if err := s.openState(); err != nil {
			return nil, err
		}
	}
	sub, _ := fs.Sub(staticFS, "static")
	s.static = http.StripPrefix("/static/", http.FileServer(http.FS(sub)))
	s.checkSyntaxFile()
	ix.Scan()
	s.rebuild(s.scanResources())
	return s, nil
}

// Run rescans the folder when it changes and every Config.Poll, and sends
// due notifications
// until ctx is done.
func (s *Server) Run(ctx context.Context) {
	go func() {
		<-ctx.Done()
		s.events.close()
	}()
	if s.sender != nil {
		go s.sender.Run(ctx)
	}
	if s.pomo != nil {
		go func() {
			<-ctx.Done()
			s.pomo.Close()
			s.clocks.Close()
		}()
	}
	// the calendar's current entry changes with the time of day
	go func() {
		t := time.NewTicker(20 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.trackSync()
			}
		}
	}()
	if len(s.cfg.Feeds) > 0 {
		r := &feeds.Runner{Root: s.cfg.Root, Ext: s.cfg.Ext, Feeds: s.cfg.Feeds, Log: s.log, OnWrite: s.Refresh}
		r.Run(ctx)
	}
	var changes <-chan struct{}
	if !s.cfg.NoWatch {
		changes = watchFolder(ctx, s.cfg.Root, s.log.Printf)
	}
	var tick <-chan time.Time
	if s.cfg.Poll > 0 {
		t := time.NewTicker(s.cfg.Poll)
		defer t.Stop()
		tick = t.C
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick:
			s.Refresh()
		case _, ok := <-changes:
			if !ok {
				changes = nil // watching stopped: the timer goes on
				continue
			}
			s.Refresh()
		}
	}
}

// Refresh rescans the folder now and rebuilds when a note, resource or
// Markdown file changed.
func (s *Server) Refresh() {
	if s.checkSyntaxFile() {
		s.ix.Forget() // labels read differently: every note again
	}
	notesChanged, rels := s.ix.ScanChanges()
	res, linking, fp := s.scanResources()
	if notesChanged || fp != s.current().fingerprint {
		s.rebuild(res, linking, fp)
	}
	s.notesChanged(rels)
	s.checkXPFile()
	s.trackSync()
}

func (s *Server) rebuild(res []resource, linking []string, fingerprint uint64) {
	s.rebuildMu.Lock()
	defer s.rebuildMu.Unlock()
	start := time.Now()
	all := s.ix.All()
	snap := &snapshot{
		search:    search.BuildAll(s.ix),
		backlinks: map[string][]Backlink{},
		inner:     map[string][]Backlink{},
		notes:     len(all),

		resources:     res,
		fileBacklinks: map[string][]Backlink{},
		names:         byBasename(res),
		fingerprint:   fingerprint,
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
		s.collectFileLinks(doc, snap, snap.names)
	}
	for _, rel := range linking {
		s.collectMarkdownLinks(rel, snap, snap.names)
	}
	for _, rel := range s.ix.Documents() {
		if s.ix.DocumentKind(rel) == "html" {
			if doc := s.ix.Doc(rel); doc != nil {
				s.collectPageLinks(doc, snap, snap.names)
			}
		}
	}
	snap.broken = append(snap.broken, s.mirrorIssues()...)
	snap.unlinked = snap.unlinkedIn()
	snap.forward = map[string][]outLink{}
	for to, list := range snap.backlinks {
		for _, b := range list {
			if b.FromNote {
				snap.forward[b.From] = append(snap.forward[b.From], outLink{b.Lnum, to})
			}
		}
	}
	for rel, list := range snap.forward {
		sort.Slice(list, func(i, j int) bool {
			if list[i].Lnum != list[j].Lnum {
				return list[i].Lnum < list[j].Lnum
			}
			return list[i].To < list[j].To
		})
		// a line linking a note twice ([OKR] [OKR/#Goals]) is one link to it
		out := list[:0]
		for i, l := range list {
			if i == 0 || l != list[i-1] {
				out = append(out, l)
			}
		}
		snap.forward[rel] = out
	}
	snap.structure = s.buildStructure(snap)
	snap.nav = s.buildNavMenu(all)
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
	s.log.Printf("indexed %d notes, %d links (%d broken), %d resources (%d unlinked) in %s; heap %d MB", snap.notes, snap.links,
		len(snap.broken), len(snap.resources), snap.unlinked[""], snap.took.Round(time.Millisecond), ms.HeapInuse>>20)
}

// collectLinks resolves every link in doc (outside code) to its canonical
// target, as the plugin's link index does. Archived notes have no broken
// links: they're left as they were.
func (s *Server) collectLinks(doc *notes.Document, snap *snapshot) {
	archived := s.ix.IsArchived(doc.Rel)
	for lnum := range doc.Lines {
		lnum++
		if doc.InCode(lnum) {
			continue
		}
		syntax.Walk(doc.Spans(lnum), func(sp *syntax.Span) {
			if sp.Type != "link" && sp.Type != "live_link" {
				return
			}
			if s.fileLike(sp.Definition) {
				return // a file: collectFileLinks
			}
			snap.links++
			r, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: doc, Lnum: lnum})
			if err != nil || r == nil {
				if archived || links.OSPath(sp.Definition) {
					return // a file on the computer ([~/Documents/x], [/home/me/x]): never broken
				}
				msg := "no match"
				if err != nil {
					msg = err.Error()
				}
				snap.broken = append(snap.broken, Broken{From: doc.Rel, FromNote: true, Lnum: lnum, Def: sp.Definition, Err: msg})
				return
			}
			if r.Doc.Rel == doc.Rel {
				// links within a note aren't backlinks (projects read them:
				// a linked heading with projects under it is one)
				snap.inner[doc.Rel] = append(snap.inner[doc.Rel], Backlink{From: doc.Rel, FromNote: true, Lnum: lnum, Def: sp.Definition, ToLnum: r.Lnum})
				return
			}
			b := Backlink{
				From:       doc.Rel,
				FromNote:   true,
				Lnum:       lnum,
				Line:       doc.Lines[lnum-1],
				Breadcrumb: doc.NodeAt(lnum).Breadcrumb(" › "),
				Def:        sp.Definition,
				ToLnum:     r.Lnum,
			}
			snap.backlinks[r.Doc.Rel] = append(snap.backlinks[r.Doc.Rel], b)
			if s.ix.DocumentKind(r.Doc.Rel) != "" {
				// a document is a file too: "Linked from" on its page
				snap.fileBacklinks[r.Doc.Rel] = append(snap.fileBacklinks[r.Doc.Rel], b)
			}
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
	// Pages, and each page's data as JSON at /api + its path (pagejson.go)
	page := func(path string, h http.HandlerFunc) {
		mux.HandleFunc("GET "+path, h)
		mux.HandleFunc("GET /api"+path, h)
	}
	mux.HandleFunc("GET /{$}", s.handleHome)
	mux.HandleFunc("GET /n/{rel...}", s.handleNote)
	page("/f/{rel...}", s.handleFiles)
	mux.HandleFunc("GET /raw/{rel...}", s.handleRaw)
	mux.HandleFunc("GET /search", s.handleSearch)
	mux.HandleFunc("GET /link", s.handleLink)
	page("/tags", s.handleTags)
	page("/tag/{name}", s.handleTag)
	page("/broken", s.handleBroken)
	page("/projects", s.handleProjects)
	page("/project", s.handleProject)
	page("/okr", s.handleOKR)
	page("/areas", s.handleAreas)
	page("/attributes", s.handleAttributes)
	page("/review", s.handleReview)
	mux.HandleFunc("GET /graph", s.handleGraph)
	mux.HandleFunc("GET /resources", s.handleResources)
	mux.HandleFunc("GET /search/open", s.handleSearchOpen) // a search result's link: counts it, then goes there
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /health", s.handleHealth)
	// notes: read one, change a line (-writable), add to the inbox
	mux.HandleFunc("GET /api/n/{rel...}", s.apiNote)
	mux.HandleFunc("POST /api/n/{rel...}", s.apiEdit)
	mux.HandleFunc("POST /api/inbox", s.apiInbox)
	mux.HandleFunc("POST /api/project/log", s.apiProjectLog)
	mux.HandleFunc("POST /api/review/note", s.apiReviewNote)
	mux.HandleFunc("POST /api/review/focus", s.apiReviewFocus)
	mux.HandleFunc("POST /api/review/move", s.apiReviewMove)
	mux.HandleFunc("POST /api/review/tomorrow", s.apiReviewTomorrow)
	mux.HandleFunc("POST /api/review/due", s.apiReviewDue)
	mux.HandleFunc("POST /api/review/area", s.apiReviewArea)
	mux.HandleFunc("POST /api/review/finish", s.apiReviewFinish)
	// finding things
	mux.HandleFunc("GET /api/search", s.apiSearch)
	mux.HandleFunc("GET /api/link", s.apiResolve)
	mux.HandleFunc("GET /api/backlinks", s.apiBacklinks)
	mux.HandleFunc("GET /api/hover", s.apiHover)
	mux.HandleFunc("GET /api/resources", s.apiResources)
	mux.HandleFunc("GET /api/tagtable", s.apiTagTable)
	mux.HandleFunc("GET /api/graph", s.apiStructure)
	// the calendar, its notifications (Neovim syncs them) and their alerts
	mux.HandleFunc("GET /api/calendar", s.apiCalendar)
	mux.HandleFunc("POST /api/calendar/carry", s.apiCarry)
	mux.HandleFunc("POST /api/calendar/repeat", s.apiRepeat)
	mux.HandleFunc("GET /api/notifications", s.apiNotifications)
	mux.HandleFunc("POST /api/notifications", s.apiNotificationAdd)
	mux.HandleFunc("POST /api/notifications/sync", s.apiNotificationsSync)
	mux.HandleFunc("POST /api/notifications/clear", s.apiNotificationsClear)
	mux.HandleFunc("POST /api/notifications/test", s.apiNotificationTest)
	mux.HandleFunc("GET /api/alerts", s.apiAlerts)
	mux.HandleFunc("GET /api/summary", s.apiSummary)
	mux.HandleFunc("GET /api/bookmarks", s.apiBookmarks)
	mux.HandleFunc("GET /api/bookmarks/cards", s.apiBookmarkCards)
	mux.HandleFunc("POST /api/bookmarks", s.apiBookmarkAdd)
	mux.HandleFunc("POST /api/bookmarks/remove", s.apiBookmarkRemove)
	// pomodoro, shared by Neovim and the home page
	mux.HandleFunc("GET /api/pomodoro", s.apiPomodoro)
	mux.HandleFunc("POST /api/pomodoro/{action}", s.apiPomodoroAction)
	// timers, alarms and the stopwatch (home page)
	mux.HandleFunc("GET /api/clocks", s.apiClocks)
	mux.HandleFunc("POST /api/clocks/timers", s.apiTimerAdd)
	mux.HandleFunc("POST /api/clocks/timers/{id}/{action}", s.apiTimerAction)
	mux.HandleFunc("POST /api/clocks/alarms", s.apiAlarmAdd)
	mux.HandleFunc("POST /api/clocks/alarms/{id}/{action}", s.apiAlarmAction)
	mux.HandleFunc("POST /api/clocks/stopwatch/{action}", s.apiStopwatch)
	// time on tasks (-writable)
	mux.HandleFunc("GET /api/track", s.apiTrack)
	mux.HandleFunc("GET /api/track/tasks", s.apiTrackTasks)
	mux.HandleFunc("POST /api/track/pin", s.apiTrackPin)
	mux.HandleFunc("POST /api/track/{mode}", s.apiTrackMode)
	// XP summary published by Neovim (the ledger lives there)
	mux.HandleFunc("GET /api/xp", s.apiXP)
	mux.HandleFunc("POST /api/xp", s.apiXPPost)
	// live updates, and pages opened from Neovim
	mux.HandleFunc("GET /api/events", s.apiEvents)
	mux.HandleFunc("POST /api/presence", s.apiPresence)
	mux.HandleFunc("POST /api/open", s.apiOpen)
	mux.HandleFunc("POST /api/open/ack", s.apiOpenAck)
	mux.HandleFunc("/api/", s.apiNotFound)
	mux.Handle("GET /static/", s.cacheStatic(s.static))
	// installable app (pwa.go)
	mux.HandleFunc("GET /manifest.webmanifest", s.handleManifest)
	mux.HandleFunc("GET /sw.js", s.handleServiceWorker)
	mux.HandleFunc("GET /offline", s.handleOffline)
	mux.HandleFunc("GET /calendar.ics", s.handleShareICS)
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
	if s.cfg.HTMLScripts {
		h = htmlScriptsGuard(h)
	}
	return securityHeaders(s.requireLogin(h))
}

// htmlScriptsGuard refuses requests that change state when they come from a
// sandboxed document (Origin: null), so an HTML file's script can't edit
// notes or drive the clocks with the browser's saved login.
func htmlScriptsGuard(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Header.Get("Origin") == "null" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hd := w.Header()
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("Referrer-Policy", "same-origin")
		h.ServeHTTP(w, r)
	})
}

// staticVersion changes with the embedded static files, so a new build's
// pages never run an hour-old cached script or stylesheet.
var staticVersion = func() string {
	h := fnv.New64a()
	_ = fs.WalkDir(staticFS, "static", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if raw, err := staticFS.ReadFile(p); err == nil {
				h.Write([]byte(p))
				h.Write(raw)
			}
		}
		return nil
	})
	return strconv.FormatUint(h.Sum64(), 36)
}()

// assetURL: a static file's URL, versioned.
func (s *Server) assetURL(p string) string { return s.url(p) + "?v=" + staticVersion }

func (s *Server) cacheStatic(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=3600")
		h.ServeHTTP(w, r)
	})
}

// url is an app path ("/n/x.zortex") with the base prefix.
func (s *Server) url(p string) string { return s.cfg.Base + p }

// noteURL links to a note, optionally at a line; a document (notes
// documents.go) to its file page: a Markdown file as rendered, an HTML page
// as its readable text (the lines a link names).
func (s *Server) noteURL(rel string, lnum int) string {
	var u string
	switch s.ix.DocumentKind(rel) {
	case "markdown":
		u = s.fileURL(rel)
	case "html":
		u = s.fileURL(rel) + "?view=readable"
	default:
		u = s.url("/n/" + escapePath(rel))
	}
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
