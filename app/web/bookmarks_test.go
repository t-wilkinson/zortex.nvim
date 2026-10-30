package web

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBookmarkURL(t *testing.T) {
	s := &Server{}
	for in, want := range map[string]string{
		"/n/projects.zortex":            "/n/projects.zortex",
		"/n/projects.zortex#L12":        "/n/projects.zortex",
		"/review?day=today":             "/review?day=today",
		"/f/z/books/":                   "/f/z/books/",
		"/raw/z/books/a%20b.pdf":        "/raw/z/books/a%20b.pdf",
		"/n/../n/x.zortex":              "/n/x.zortex",
		"/":                             "/",
		"/api/bookmarks":                "",
		"/static/style.css":             "",
		"//evil.example/x":              "",
		"https://evil.example/n/x":      "",
		"n/x.zortex":                    "",
		"/healthz":                      "",
		"/calendar.ics?token=secret123": "",
	} {
		got, ok := s.bookmarkURL(in)
		if (want == "") == ok || got != want {
			t.Errorf("bookmarkURL(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	// below -base, the base is left out (and required)
	s.cfg.Base = "/notes"
	if got, ok := s.bookmarkURL("/notes/n/x.zortex?view=slides"); !ok || got != "/n/x.zortex?view=slides" {
		t.Errorf("with -base: %q %v", got, ok)
	}
	if _, ok := s.bookmarkURL("/n/x.zortex"); ok {
		t.Error("outside -base accepted")
	}
}

// The star keeps a page on the server; the home page shows it as a card,
// on any device, and after a restart.
func TestBookmarks(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "")
	os.MkdirAll(filepath.Join(dir, "z", "books"), 0o755)
	os.WriteFile(filepath.Join(dir, "z", "books", "cover.png"), []byte("png"), 0o644)
	s.Refresh()

	// a note page has the star, not pressed
	page := expect(t, ts, "/n/projects.zortex", 200, `id="bm-toggle" data-url="/n/projects.zortex" aria-pressed="false"`)
	_ = page
	expect(t, ts, "/", 200, `id="bm-cards"`, "Nothing bookmarked yet")

	for _, b := range []map[string]any{
		{"url": "/n/projects.zortex#L3", "title": "Projects"},
		{"url": "/review?day=today", "title": "Daily review"},
		{"url": "/f/z/books/"},
		{"url": "/raw/z/books/cover.png"},
		{"url": "/n/gone.zortex", "title": "Gone"},
	} {
		if code, out := postJSON(t, ts.URL, "/api/bookmarks", b); code != 200 || out["ok"] != true {
			t.Fatalf("add %v: %d %v", b["url"], code, out)
		}
	}
	// adding again changes nothing
	postJSON(t, ts.URL, "/api/bookmarks", map[string]any{"url": "/review?day=today", "title": "Daily review"})
	if n := len(s.bookmarks.List()); n != 5 {
		t.Fatalf("%d bookmarks, want 5", n)
	}
	expect(t, ts, "/n/projects.zortex", 200, `aria-pressed="true"`, "★")

	home := expect(t, ts, "/", 200,
		`data-url="/n/projects.zortex" data-kind="note"`,
		`<span class="bm-kind">note</span>`,
		`data-url="/review?day=today" data-kind="page"`, `<h3>Daily review</h3>`,
		`data-url="/f/z/books/" data-kind="folder"`, `<h3>books/</h3>`,
		`data-url="/raw/z/books/cover.png" data-kind="image"`, `<img class="bm-image" src="/raw/z/books/cover.png"`,
		`bm-card missing`, "not there any more")
	// newest first
	if strings.Index(home, `data-url="/n/gone.zortex"`) > strings.Index(home, `data-url="/n/projects.zortex"`) {
		t.Error("newest first")
	}
	// the cards alone, and as JSON
	expect(t, ts, "/api/bookmarks/cards", 200, `class="bm-card`)
	if code, out := getJSON(t, ts, "/api/bookmarks"); code != 200 || len(out["bookmarks"].([]any)) != 5 {
		t.Fatalf("GET /api/bookmarks: %d %v", code, out)
	}

	// a form post from another site can't add one
	resp, err := http.Post(ts.URL+"/api/bookmarks", "application/x-www-form-urlencoded", strings.NewReader("url=/n/x"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Errorf("form post: %d", resp.StatusCode)
	}
	if code, _ := postJSON(t, ts.URL, "/api/bookmarks", map[string]any{"url": "https://example.com"}); code != http.StatusUnprocessableEntity {
		t.Errorf("another site: %d", code)
	}

	// remove
	if code, out := postJSON(t, ts.URL, "/api/bookmarks/remove", map[string]any{"url": "/n/gone.zortex"}); code != 200 || out["bookmarked"] != false {
		t.Fatalf("remove: %d %v", code, out)
	}
	// kept on the server: a restarted server (another device's view) has them
	s2, err := New(Config{Root: dir, DataDir: s.cfg.DataDir})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s2.pomo.Close)
	t.Cleanup(s2.clocks.Close)
	if got := s2.bookmarks.List(); len(got) != 4 || got[len(got)-1].URL != "/n/projects.zortex" {
		t.Fatalf("after a restart: %+v", got)
	}
}

// Without -data there is nowhere to keep them: no star, no section.
func TestBookmarksNeedData(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	_, _, body := get(t, ts, "/n/projects.zortex")
	if strings.Contains(body, "bm-toggle") {
		t.Error("a star without -data")
	}
	if _, _, home := get(t, ts, "/"); strings.Contains(home, "bm-cards") {
		t.Error("bookmarks on the home page without -data")
	}
	if code, _ := postJSON(t, ts.URL, "/api/bookmarks", map[string]any{"url": "/"}); code != http.StatusServiceUnavailable {
		t.Errorf("add without -data: %d", code)
	}
}
