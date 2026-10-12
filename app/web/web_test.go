package web

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newTestServer serves a copy of tests/fixtures/notes plus a few other files.
func newTestServer(t *testing.T, base string) (*Server, string, *httptest.Server) {
	t.Helper()
	dir := t.TempDir()
	src := "../../tests/fixtures/notes"
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dir, rel), 0o755)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dir, rel), data, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"z/docs/manual.pdf":   "%PDF-1.4 test",
		"z/docs/page.html":    "<script>alert(1)</script>",
		"z/docs/notes.txt":    "plain <text>",
		".z/state.json":       "{}",
		"z/a.sync-conflict-1": "x",
		"links.zortex": "@@Links\n\n- [P/#1.4 - zortex] and [Nope/#x] and [/#Local]\n" +
			"- file ./z/docs/manual.pdf, [doc](z/docs/notes.txt), https://example.com\n" +
			"# Local\n```\n[P] in code\n```\n| [P] | b |\n",
	}
	for rel, content := range files {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	s, err := New(Config{Root: dir, Base: base, Poll: -1, Logger: log.New(io.Discard, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return s, dir, ts
}

func get(t *testing.T, ts *httptest.Server, path string) (int, http.Header, string) {
	t.Helper()
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Get(ts.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(body)
}

func expect(t *testing.T, ts *httptest.Server, path string, status int, contains ...string) string {
	t.Helper()
	code, _, body := get(t, ts, path)
	if code != status {
		t.Errorf("GET %s: status %d, want %d", path, code, status)
	}
	for _, c := range contains {
		if !strings.Contains(body, c) {
			t.Errorf("GET %s: body lacks %q", path, c)
		}
	}
	return body
}

func TestNotePage(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	body := expect(t, ts, "/n/links.zortex", 200,
		`<h1>Links</h1>`,
		`href="/n/projects.zortex#L14"`, // [P/#1.4 - zortex] resolves to the heading
		`class="zl broken"`,             // [Nope/#x]
		`href="/n/links.zortex#L5"`,     // local link [/#Local]
		`href="/f/z/docs/manual.pdf"`,   // ./path
		`href="/f/z/docs/notes.txt"`,    // markdown link to a file
		`target="_blank" rel="noopener noreferrer"`,
		`<span class="cl" id="L7">[P] in code`, // code stays text
		`<table>`,
	)
	if strings.Contains(body, `in code</a>`) {
		t.Error("link rendered inside a code block")
	}
	// backlinks: the calendar links to projects
	expect(t, ts, "/n/projects.zortex", 200, `id="backlinks"`, `/n/calendar.zortex#L5`, `/n/links.zortex#L3`)
	expect(t, ts, "/n/projects", 302)
	expect(t, ts, "/n/missing.zortex", 404)
}

func TestSearch(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	expect(t, ts, "/search?q=car+subaru", 200, `Subaru`, `/n/flipping.zortex#L`)
	partial := expect(t, ts, "/search?q=zortex&partial=1", 200, `<mark>`)
	if strings.Contains(partial, "<html") {
		t.Error("partial results include the layout")
	}
	expect(t, ts, "/search?mode=article&q=o", 200, `Objectives`)

	_, _, body := get(t, ts, "/api/search?q=subaru")
	var res []map[string]any
	if err := json.Unmarshal([]byte(body), &res); err != nil || len(res) == 0 {
		t.Fatalf("api/search: %v %s", err, body)
	}
}

func TestLinkPage(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	code, h, _ := get(t, ts, "/link?to=Projects/%231%20Programming/%231.4%20-%20zortex")
	if code != 302 || h.Get("Location") != "/n/projects.zortex#L14" {
		t.Errorf("single target should redirect, got %d %s", code, h.Get("Location"))
	}
	expect(t, ts, "/link?to=P", 200, "matches")
	expect(t, ts, "/link?to=Nope", 404, "No article found: Nope")
	_, _, body := get(t, ts, "/api/resolve?to=[P/%23Subaru]")
	if !strings.Contains(body, `"rel":"flipping.zortex"`) {
		t.Errorf("api/resolve: %s", body)
	}
}

func TestFiles(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	root := expect(t, ts, "/f/", 200, `z/`, `Calendar`, `Show all`)
	if strings.Contains(root, "Links") || strings.Contains(root, `"/f/.z"`) {
		t.Error("root lists non-special top-level notes or hidden folders")
	}
	expect(t, ts, "/f/?all=1", 200, `Links`)
	docs := expect(t, ts, "/f/z/docs", 200, `manual.pdf`, `notes.txt`)
	if strings.Contains(docs, "sync-conflict") {
		t.Error("sync artefact listed")
	}
	expect(t, ts, "/f/z/docs/manual.pdf", 200, `<iframe class="view doc"`)
	expect(t, ts, "/f/z/docs/notes.txt", 200, `plain &lt;text&gt;`)
	expect(t, ts, "/f/projects.zortex", 302)

	_, h, body := get(t, ts, "/raw/z/docs/page.html")
	if h.Get("Content-Security-Policy") != "sandbox" || h.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("active content not sandboxed: %v", h)
	}
	if body != "<script>alert(1)</script>" {
		t.Error("raw body")
	}
	_, h, _ = get(t, ts, "/raw/z/docs/manual.pdf?download=1")
	if !strings.HasPrefix(h.Get("Content-Disposition"), "attachment") || h.Get("Content-Type") != "application/pdf" {
		t.Errorf("download headers: %v", h)
	}
	// (the mux answers "/../" with a redirect to the cleaned path)
	for _, p := range []string{"/raw/../etc/passwd", "/raw/%2e%2e/%2e%2e/etc/passwd", "/raw/.z/state.json", "/f/.z", "/raw/z", "/raw/z/../../x"} {
		if code, _, body := get(t, ts, p); code != 404 && code != 301 || strings.Contains(body, "root:") {
			t.Errorf("GET %s: %d, want 404", p, code)
		}
	}
}

func TestRangeRequest(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	req, _ := http.NewRequest("GET", ts.URL+"/raw/z/docs/manual.pdf", nil)
	req.Header.Set("Range", "bytes=0-3")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 206 || string(body) != "%PDF" {
		t.Errorf("range: %d %q", resp.StatusCode, body)
	}
}

func TestOtherPages(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	expect(t, ts, "/", 200, `Recently changed`, `Calendar`)
	expect(t, ts, "/tags", 200, `@P`, `@Cars`)
	expect(t, ts, "/tag/p", 200, `flipping.zortex`)
	expect(t, ts, "/tag/nope", 404)
	expect(t, ts, "/broken", 200, `[Nope/#x]`, `links.zortex:3`)
	expect(t, ts, "/healthz", 200, `"ok":true`)
	expect(t, ts, "/static/style.css", 200, `--accent`)
}

func TestBasePath(t *testing.T) {
	_, _, ts := newTestServer(t, "/notes/")
	expect(t, ts, "/notes/n/links.zortex", 200, `href="/notes/n/projects.zortex#L14"`, `href="/notes/static/style.css"`)
	if code, _, _ := get(t, ts, "/n/links.zortex"); code != 404 {
		t.Error("served outside the base path")
	}
}

func TestRefresh(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	expect(t, ts, "/search?q=brandnew", 200)
	p := filepath.Join(dir, "z/new.zortex")
	os.WriteFile(p, []byte("@@New\n# Brandnew heading\n- [Links]\n"), 0o644)
	s.Refresh()
	expect(t, ts, "/search?q=brandnew", 200, `/n/z/new.zortex#L2`)
	expect(t, ts, "/n/links.zortex", 200, `/n/z/new.zortex#L3`) // new backlink
	os.Remove(p)
	s.Refresh()
	expect(t, ts, "/n/z/new.zortex", 404)
	if took := s.current().took; took > 5*time.Second {
		t.Errorf("rebuild took %s", took)
	}
}
