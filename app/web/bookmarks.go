package web

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Bookmarks: pages of the site kept on the server (-data/bookmarks.json),
// so every device sees the same ones. The top bar's ☆ adds or removes the
// page it is on; the home page shows them as cards: a note with its first
// lines and tags, a file or folder with its kind (an image with itself),
// any other page with its title. A file's own address (/raw/z/scan.pdf)
// can be kept too: its card is the file's, and it opens the file itself.
//
//	GET  /api/bookmarks           {bookmarks: [{url, title, added, kind, …card}]}
//	GET  /api/bookmarks/cards     the home page's cards (HTML)
//	POST /api/bookmarks           {url, title?}: add (again: no change) -> {ok, bookmarked}
//	POST /api/bookmarks/remove    {url} -> {ok, bookmarked: false}
//
// A bookmark's url is the page's path and query on this site, without
// -base or a #fragment ("/n/projects.zortex", "/review?day=today").

// maxBookmarks: the most kept; adding one more drops the oldest.
const maxBookmarks = 200

// Bookmark is a page kept on the home page.
type Bookmark struct {
	URL   string    `json:"url"`
	Title string    `json:"title,omitempty"` // the page's title when it was added
	Added time.Time `json:"added"`
}

type bookmarkStore struct {
	mu   sync.Mutex
	path string
	data struct {
		Version   int        `json:"version"`
		Bookmarks []Bookmark `json:"bookmarks"` // newest first
	}
}

func openBookmarks(file string) (*bookmarkStore, error) {
	b := &bookmarkStore{path: file}
	b.data.Version = 1
	raw, err := os.ReadFile(file)
	if errors.Is(err, fs.ErrNotExist) {
		return b, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(raw, &b.data); err != nil {
		return nil, err
	}
	b.data.Version = 1
	return b, nil
}

func (b *bookmarkStore) save() error {
	raw, err := json.MarshalIndent(b.data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(b.path), 0o750); err != nil {
		return err
	}
	tmp := b.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, b.path)
}

// List: the bookmarks, newest first.
func (b *bookmarkStore) List() []Bookmark {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]Bookmark(nil), b.data.Bookmarks...)
}

// Has: whether the page is bookmarked.
func (b *bookmarkStore) Has(u string) bool {
	if b == nil {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, x := range b.data.Bookmarks {
		if x.URL == u {
			return true
		}
	}
	return false
}

// Add keeps the page first (a title update when it's there already); reports
// whether anything changed.
func (b *bookmarkStore) Add(u, title string, now time.Time) (bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for i, x := range b.data.Bookmarks {
		if x.URL == u {
			if title == "" || title == x.Title {
				return false, nil
			}
			b.data.Bookmarks[i].Title = title
			return true, b.save()
		}
	}
	b.data.Bookmarks = append([]Bookmark{{URL: u, Title: title, Added: now.UTC()}}, b.data.Bookmarks...)
	if len(b.data.Bookmarks) > maxBookmarks {
		b.data.Bookmarks = b.data.Bookmarks[:maxBookmarks]
	}
	return true, b.save()
}

// Remove drops the page; reports whether it was there.
func (b *bookmarkStore) Remove(u string) (bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for i, x := range b.data.Bookmarks {
		if x.URL == u {
			b.data.Bookmarks = append(b.data.Bookmarks[:i], b.data.Bookmarks[i+1:]...)
			return true, b.save()
		}
	}
	return false, nil
}

// bookmarkURL: a page address as a bookmark keeps it, its path and query
// on this site (-base and any #fragment left out); ok is false for anything
// that isn't a page here (another site, the API, static files).
func (s *Server) bookmarkURL(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > 2048 || !strings.HasPrefix(raw, "/") || strings.HasPrefix(raw, "//") {
		return "", false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "" || u.Host != "" {
		return "", false
	}
	p := u.Path
	if base := s.cfg.Base; base != "" {
		if p != base && !strings.HasPrefix(p, base+"/") {
			return "", false
		}
		p = strings.TrimPrefix(p, base)
	}
	if p == "" {
		p = "/"
	}
	trailing := strings.HasSuffix(p, "/") && p != "/"
	p = path.Clean(p)
	if trailing {
		p += "/" // a folder: /f/z/
	}
	for _, no := range []string{"/api/", "/static/", "/sw.js", "/manifest.webmanifest", "/healthz", "/health", "/calendar.ics"} {
		if strings.HasPrefix(p+"/", no) || p == strings.TrimSuffix(no, "/") {
			return "", false
		}
	}
	out := (&url.URL{Path: p}).EscapedPath()
	if u.RawQuery != "" {
		out += "?" + u.RawQuery
	}
	return out, true
}

// bookmarkKeyOf: the bookmark address of the page a request shows.
func (s *Server) bookmarkKeyOf(r *http.Request) string {
	if r == nil {
		return ""
	}
	k, ok := s.bookmarkURL(s.cfg.Base + r.URL.RequestURI())
	if !ok {
		return ""
	}
	return k
}

// bookmarkCard: what the home page shows for a bookmark.
type bookmarkCard struct {
	URL       string   `json:"url"`  // the bookmark's address
	Href      string   `json:"href"` // where it opens (with -base)
	Title     string   `json:"title"`
	Kind      string   `json:"kind"`            // note, folder, pdf, image, …, page
	Where     string   `json:"where,omitempty"` // a note's or file's path, a page's address
	Tags      []string `json:"tags,omitempty"`
	Lines     []string `json:"lines,omitempty"` // a note's first lines
	Backlinks int      `json:"backlinks,omitempty"`
	Image     string   `json:"image,omitempty"` // an image's own address
	Missing   bool     `json:"missing,omitempty"`
	Added     string   `json:"added"`
}

// pageTitles: the titles of the pages that aren't notes or files, for a
// bookmark added without one.
var pageTitles = map[string]string{"/": "Home", "/projects": "Projects", "/project": "Project", "/okr": "Objectives", "/areas": "Areas",
	"/review": "Review", "/graph": "Graph", "/tags": "Tags", "/broken": "Broken links", "/attributes": "Attributes", "/search": "Search", "/link": "Link", "/offline": "Saved pages"}

func (s *Server) bookmarkCardOf(b Bookmark) bookmarkCard {
	c := bookmarkCard{URL: b.URL, Href: s.url(b.URL), Title: b.Title, Kind: "page", Where: b.URL, Added: b.Added.Format("2006-01-02")}
	u, _ := url.Parse(b.URL)
	p := u.Path
	switch {
	case strings.HasPrefix(p, "/n/"):
		rel, _ := url.PathUnescape(strings.TrimPrefix(p, "/n/"))
		c.Kind, c.Where = "note", rel
		card, ok := s.hoverCardOf(rel, 0, 3)
		if !ok {
			c.Missing = true
			break
		}
		c.Title, c.Tags, c.Lines, c.Backlinks = card.Title, card.Tags, card.Lines, card.Backlinks
	case p == "/f" || strings.HasPrefix(p, "/f/") || strings.HasPrefix(p, "/raw/"):
		// the file viewer (/f/…) or the file itself (/raw/z/scan.pdf)
		rest := strings.TrimPrefix(p, "/f")
		if strings.HasPrefix(p, "/raw/") {
			rest = strings.TrimPrefix(p, "/raw")
		}
		rel, _ := url.PathUnescape(strings.Trim(rest, "/"))
		c.Where = rel + "/"
		st, err := os.Stat(s.ix.Path(rel))
		switch {
		case rel == "":
			c.Kind, c.Title, c.Where = "folder", "Files", "/"
		case err == nil && st.IsDir():
			c.Kind, c.Title = "folder", path.Base(rel)+"/"
		case err != nil:
			c.Kind, c.Where, c.Missing = "file", rel, true
		case s.isNote(rel):
			c.Kind, c.Where = "note", rel
			if card, ok := s.hoverCardOf(rel, 0, 3); ok {
				c.Title, c.Tags, c.Lines, c.Backlinks = card.Title, card.Tags, card.Lines, card.Backlinks
			}
		default:
			c.Kind, c.Where, c.Title = resourceKind(extOf(rel)), rel, path.Base(rel)
			if c.Kind == "image" {
				c.Image = s.rawURL(rel)
			}
		}
	default:
		if c.Title == "" {
			c.Title = pageTitles[p]
		}
		if c.Title == "" {
			c.Title = b.URL
		}
	}
	if c.Title == "" {
		c.Title = path.Base(c.Where)
	}
	return c
}

func (s *Server) bookmarkCards() []bookmarkCard {
	var out []bookmarkCard
	for _, b := range s.bookmarks.List() {
		out = append(out, s.bookmarkCardOf(b))
	}
	return out
}

func (s *Server) bookmarksOn(w http.ResponseWriter) bool {
	if s.bookmarks == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "no data directory: start zortex serve with -data to keep bookmarks"})
		return false
	}
	return true
}

// GET /api/bookmarks
func (s *Server) apiBookmarks(w http.ResponseWriter, r *http.Request) {
	if !s.bookmarksOn(w) {
		return
	}
	cards := s.bookmarkCards()
	if cards == nil {
		cards = []bookmarkCard{}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"bookmarks": cards})
}

// GET /api/bookmarks/cards: the home page's cards, as HTML
func (s *Server) apiBookmarkCards(w http.ResponseWriter, r *http.Request) {
	if !s.bookmarksOn(w) {
		return
	}
	var buf strings.Builder
	if err := s.pages["home"].ExecuteTemplate(&buf, "bookmarkCards", s.bookmarkCards()); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(buf.String()))
}

func (s *Server) bookmarkRequest(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	if !s.bookmarksOn(w) {
		return "", "", false
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json)"})
		return "", "", false
	}
	var req struct {
		URL   string `json:"url"`
		Title string `json:"title"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return "", "", false
	}
	u, ok := s.bookmarkURL(req.URL)
	if !ok {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "not a page of this site: " + req.URL})
		return "", "", false
	}
	title := strings.Join(strings.Fields(req.Title), " ")
	if len(title) > 200 {
		title = title[:200]
	}
	return u, title, true
}

// POST /api/bookmarks {url, title?}
func (s *Server) apiBookmarkAdd(w http.ResponseWriter, r *http.Request) {
	u, title, ok := s.bookmarkRequest(w, r)
	if !ok {
		return
	}
	changed, err := s.bookmarks.Add(u, title, time.Now())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if changed {
		s.events.publish("bookmarks", map[string]any{"url": u, "bookmarked": true})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "url": u, "bookmarked": true})
}

// POST /api/bookmarks/remove {url}
func (s *Server) apiBookmarkRemove(w http.ResponseWriter, r *http.Request) {
	u, _, ok := s.bookmarkRequest(w, r)
	if !ok {
		return
	}
	changed, err := s.bookmarks.Remove(u)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if changed {
		s.events.publish("bookmarks", map[string]any{"url": u, "bookmarked": false})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "url": u, "bookmarked": false})
}
