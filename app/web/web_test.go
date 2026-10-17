package web

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
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
		"z/docs/manual.pdf":     "%PDF-1.4 test",
		"z/docs/page.html":      "<script>alert(1)</script>",
		"z/docs/notes.txt":      "plain <text>",
		".z/state.json":         "{}",
		"z/a.sync-conflict-1":   "x",
		"2026-10-15.042.zortex": "@@Quick thought\n",
		"links.zortex": "@@Links\n\n- [P/#1.4 - zortex] and [Nope/#x] and [/#Local]\n" +
			"- file ./z/docs/manual.pdf, [doc](z/docs/notes.txt), https://example.com\n" +
			"# Local\n```\n[P] in code\n```\n| [P] | b |\n" +
			"- Long label: text that wraps\n",
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
	// "- Key: text" wraps under the key: key and text share one body span
	if !strings.Contains(body, `<span class="body keyed"><span class="key">Long label:</span>text that wraps</span>`) {
		t.Error("keyed item: key not inside the body span")
	}
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
	// text: the prompt as typed, spaces included, in any line
	text := expect(t, ts, "/search?mode=text&q=1.4+-+zortex", 200, `value="text" checked`, `<mark>1.4 - zortex</mark>`)
	if strings.Contains(text, `class="hit section`) {
		t.Error("text mode lists lines only")
	}

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

func TestFollowLinks(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	// one match: straight to where the matched link goes
	code, h, _ := get(t, ts, "/link?to="+url.QueryEscape("R/#Rust/>The Rust Book"))
	if code != 302 || h.Get("Location") != "https://doc.rust-lang.org/book" {
		t.Errorf("> link should redirect to its target, got %d %s", code, h.Get("Location"))
	}
	code, h, _ = get(t, ts, "/link?to="+url.QueryEscape("R/#Rust/>Flipping"))
	if code != 302 || h.Get("Location") != "/n/flipping.zortex#L11" {
		t.Errorf("> link to a zortex link, got %d %s", code, h.Get("Location"))
	}
	// several: a page to pick one
	expect(t, ts, "/link?to="+url.QueryEscape("R/#Rust/>Garden notes"), 200,
		"2 links match; pick one.", `href="/n/z/garden.zortex#L4"`, `href="/n/flipping.zortex#L11"`)
	// in a note: [R/#Rust/>The Rust Book] (a chain) goes to the book
	expect(t, ts, "/n/z/resources.zortex", 200, `<a class="zl" href="https://doc.rust-lang.org/book"`)
	_, _, body := get(t, ts, "/api/resolve?to="+url.QueryEscape("[R/>Spinning]"))
	if !strings.Contains(body, `"follow":"https://spinningup.openai.com"`) {
		t.Errorf("api/resolve follow: %s", body)
	}
}

func TestTagSearch(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	// @[rl ai-model] in the note links to the lines it finds there
	note := expect(t, ts, "/n/z/resources.zortex", 200, `class="tagsearch"`)
	if !strings.Contains(note, `href="/link?from=z%2Fresources.zortex&amp;to=%40%5Brl+ai-model%5D"`) {
		t.Errorf("tag search href: %s", note)
	}
	// shown like a link: a dim @, no brackets, alternatives spaced
	if !strings.Contains(note, `<span class="ts-at" aria-hidden="true">@</span>rust, rl</a>`) {
		t.Errorf("tag search text: %s", note)
	}
	code, h, _ := get(t, ts, "/link?from=z%2Fresources.zortex&to="+url.QueryEscape("@[rl ai-model]"))
	if code != 302 || h.Get("Location") != "/n/z/resources.zortex#L21" {
		t.Errorf("one tagged line should redirect, got %d %s", code, h.Get("Location"))
	}
	// a scope, and tags inherited from a heading
	expect(t, ts, "/link?to="+url.QueryEscape("@[R/#Rust/embedded]"), 200, "3 tagged lines.", `href="/n/z/resources.zortex#L17"`)
	expect(t, ts, "/link?to="+url.QueryEscape("@[R/nothing]"), 404, "No matches found for: @[R/nothing]")
	// a search in the note it's in, from a note the server doesn't have
	expect(t, ts, "/link?from=z%2Fmissing.zortex&to="+url.QueryEscape("@[rl]"), 404, "This server has no note z/missing.zortex")
	expect(t, ts, "/link?to="+url.QueryEscape("@[rl]"), 404, "the request didn&#39;t say which")
}

func TestTagIndex(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	note := "@@Topics hub\n\nTopics:\n- AI @[R/rl, ai-model]\n  - Reinforcement learning @[R/rl]\n" +
		"  - Models @[R/rl ai-model]\n- Embedded\n  - Rust **embedded** @[R/rust embedded]\n  - @[R/async]\n" +
		"- Gardening @[R/garden]\n- Labelled:\n  - Spinning @[R/rl]\n\nReading:\n@[R/rust]\n@[R/nothing]\n\nNot an index:\n- plain item\n- @[R/rust]\n"
	if err := os.WriteFile(filepath.Join(dir, "z/hub.zortex"), []byte(note), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	body := expect(t, ts, "/n/z/hub.zortex", 200, `<div class="tag-index" id="L3" data-from="z/hub.zortex">`)
	// one widget for both labels, its lines kept as anchors
	if strings.Count(body, `class="tag-index"`) != 1 || !strings.Contains(body, `<span class="anchor" id="L16"></span>`) {
		t.Errorf("adjacent index labels should share one widget: %s", body)
	}
	for _, want := range []string{
		// a group with its own search heads its row
		`<a class="ti-chip ti-head" href="/link?from=z%2Fhub.zortex&amp;to=%40%5BR%2Frl%2C+ai-model%5D" data-q="R/rl, ai-model" title="@[R/rl, ai-model]">AI <span class="ti-n">2</span></a>`,
		// a group without one searches everything under it
		`data-q="R/rust embedded, async" title="@[R/rust embedded, async]">Embedded <span class="ti-n">2</span>`,
		// a chip is named by its text, or by its tags
		`data-q="R/rust embedded" title="@[R/rust embedded]">Rust embedded <span class="ti-n">`,
		`data-q="R/async" title="@[R/async]">async <span class="ti-n">1</span>`,
		// no matches: dimmed
		`<a class="ti-chip none" href=`,
		`<span class="ti-head">Topics</span>`,
		// "- Labelled:" groups the items under it too
		`data-q="R/rl" title="@[R/rl]">Labelled <span class="ti-n">2</span>`,
		`data-q="R/rust, nothing" title="@[R/rust, nothing]">Reading`,
		`<div class="ti-table" aria-live="polite"></div>`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("tag index lacks %s", want)
		}
	}
	// an item without a search or items under it: an ordinary list
	if !strings.Contains(body, `<div class="ln label" id="L18">Not an index:</div>`) {
		t.Error("a label with a plain item is not an index")
	}
	// a chip's table
	expect(t, ts, "/api/tagtable?from=z%2Fhub.zortex&q="+url.QueryEscape("R/rl"), 200, `class="tag-table"`, `Spinning Up`, `class="ti-for dim"`)
	expect(t, ts, "/api/tagtable", 400)
}

func TestFiles(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	root := expect(t, ts, "/f/", 200, `z/`, `Calendar`, `href="/n/links.zortex"`, `1 note with generated names hidden`, `Show all`)
	if strings.Contains(root, `2026-10-15.042`) || strings.Contains(root, `"/f/.z"`) {
		t.Error("root lists notes with generated names or hidden folders")
	}
	expect(t, ts, "/f/?all=1", 200, `href="/n/2026-10-15.042.zortex"`, `Hide notes with generated names`)
	docs := expect(t, ts, "/f/z/docs", 200, `manual.pdf`, `notes.txt`)
	if strings.Contains(docs, "sync-conflict") {
		t.Error("sync artefact listed")
	}
	expect(t, ts, "/f/z/docs/manual.pdf", 200, `<iframe class="view doc"`)
	expect(t, ts, "/f/z/docs/page.html", 200, `sandbox="" title="page.html"`)
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
	expect(t, ts, "/", 200, `Recently changed`, `Graph`, `id="calendar-days"`, `<title>Zortex</title>`)
	expect(t, ts, "/tags", 200, `@P`, `@Cars`, `<title>Tags · Zortex</title>`)
	expect(t, ts, "/tag/p", 200, `flipping.zortex`)
	expect(t, ts, "/tag/nope", 404)
	expect(t, ts, "/broken", 200, `[Nope/#x]`, `links.zortex:3`)
	expect(t, ts, "/healthz", 200, `"ok":true`)
	expect(t, ts, "/static/style.css", 200, `--accent`)
}

func TestNav(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	home := expect(t, ts, "/", 200)
	nav := home[strings.Index(home, `<nav class="links">`):]
	if nav = nav[:strings.Index(nav, "</nav>")]; strings.Contains(nav, "Calendar") {
		t.Error("the calendar is on the home page, not a tab")
	}
	expect(t, ts, "/tags", 200, `href="/graph" aria-current="page"`)
	expect(t, ts, "/f/z", 200, `href="/f/" aria-current="page"`)
}

func TestBasePath(t *testing.T) {
	_, _, ts := newTestServer(t, "/notes/")
	expect(t, ts, "/notes/n/links.zortex", 200, `href="/notes/n/projects.zortex#L14"`, `href="/notes/static/style.css?v=`)
	if code, _, _ := get(t, ts, "/n/links.zortex"); code != 404 {
		t.Error("served outside the base path")
	}
	if code, h, _ := get(t, ts, "/notes?x=1"); code != 301 || h.Get("Location") != "/notes/?x=1" {
		t.Errorf("bare base path: %d -> %q", code, h.Get("Location"))
	}
	expect(t, ts, "/notes/", 200, `Recently changed`)
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

func TestResources(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	files := map[string]string{
		"z/books/type-theory.pdf": "%PDF tt",
		"z/books/hott.pdf":        "%PDF hott",
		"z/books/sicp.epub":       "epub",
		"z/papers/attention.pdf":  "%PDF a",
		"z/papers/unread.pdf":     "%PDF u",
		"z/images/pic.png":        "png",
		"z/videos/talk.mp4":       "mp4",
		"z/readme.md":             "# Readme\nSee ![pic](images/pic.png).\n```\n[x](videos/talk.mp4)\n```\n",
		"z/reading.zortex": "@@Reading\n\n# Books\n- [z/books/type-theory.pdf] chapter 3\n- [HoTT](z/books/hott.pdf)\n" +
			"- [attention.pdf] (bare name)\n- [./missing.pdf]\n```\n[z/papers/unread.pdf]\n```\n",
	}
	for rel, content := range files {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(content), 0o644)
	}
	s.Refresh() // new resources and a changed note

	// a file's backlinks
	expect(t, ts, "/f/z/books/type-theory.pdf", 200, `id="backlinks"`, `/n/z/reading.zortex#L4`, `Reading › Books`, `1 link<`)
	expect(t, ts, "/f/z/books/hott.pdf", 200, `/n/z/reading.zortex#L5`)
	expect(t, ts, "/f/z/papers/attention.pdf", 200, `/n/z/reading.zortex#L6`)       // bare file name
	expect(t, ts, "/f/z/images/pic.png", 200, `href="/f/z/readme.md"`, `line 2`)    // from a Markdown file
	expect(t, ts, "/f/z/papers/unread.pdf", 200, `Nothing links to this file yet.`) // only in a code block

	// every resource by default, then the unlinked list
	expect(t, ts, "/resources", 200, `unread.pdf`, `sicp.epub`, `talk.mp4`, `type-theory.pdf`, `hott.pdf`, `pic.png`,
		`<a class="chip on" href="/resources" aria-current="true">all</a>`, `href="/resources?show=unlinked"`)
	body := expect(t, ts, "/resources?show=unlinked", 200, `unread.pdf`, `sicp.epub`, `talk.mp4`)
	for _, linked := range []string{"type-theory.pdf", "hott.pdf", "attention.pdf", "pic.png"} {
		if strings.Contains(body, linked) {
			t.Errorf("/resources?show=unlinked lists linked %s", linked)
		}
	}
	expect(t, ts, "/resources?show=linked&kind=pdf", 200, `type-theory.pdf`, `attention.pdf`)
	if b := expect(t, ts, "/resources?dir=z/books", 200, `sicp.epub`); strings.Contains(b, "unread.pdf") {
		t.Error("dir filter")
	}
	_, _, js := get(t, ts, "/api/resources?kind=pdf")
	if !strings.Contains(js, `"rel":"z/papers/unread.pdf"`) || strings.Contains(js, "hott") {
		t.Errorf("api/resources: %s", js)
	}

	// listings: per-file counts and unlinked per folder
	expect(t, ts, "/f/z", 200, `href="/resources?show=unlinked&amp;dir=z%2fbooks">1 unlinked</a>`, `href="/resources?show=unlinked&amp;dir=z%2fpapers">1 unlinked</a>`)
	expect(t, ts, "/f/z/books", 200, `<span class="unlinked">unlinked</span>`, `/f/z/books/type-theory.pdf#backlinks">1</a>`)
	// rendering resolves the bare name too; a missing file is a broken link
	expect(t, ts, "/n/z/reading.zortex", 200, `href="/f/z/papers/attention.pdf"`)
	expect(t, ts, "/broken", 200, `./missing.pdf`, `File not found`)

	// a new file shows up on the next rescan, without any note changing
	os.WriteFile(filepath.Join(dir, "z/papers/new.pdf"), []byte("%PDF"), 0o644)
	s.Refresh()
	expect(t, ts, "/resources", 200, `new.pdf`)
}

func TestBrokenPathLinks(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	files := map[string]string{
		"paths.zortex": "@@Paths\n\n- [./z/garden.zortex] [./z/docs] [./z/docs/manual.pdf#page=2]\n" +
			"- [./z/gone.zortex] [../outside.zortex]\n",
		// an archived note's broken links are left alone
		"old.zortex": "@@Old\n@Archive\n\n- [Nowhere/#x] [./z/gone.pdf]\n",
	}
	for rel, content := range files {
		os.WriteFile(filepath.Join(dir, rel), []byte(content), 0o644)
	}
	s.Refresh()

	body := expect(t, ts, "/broken", 200, `./z/gone.zortex`, `../outside.zortex`, `paths.zortex:4`)
	for _, ok := range []string{"./z/garden.zortex", "./z/docs]", "manual.pdf", "Nowhere", "gone.pdf", "old.zortex"} {
		if strings.Contains(body, ok) {
			t.Errorf("/broken lists %s", ok)
		}
	}
	expect(t, ts, "/n/paths.zortex", 200, `href="/n/z/garden.zortex"`, `href="/f/z/docs"`, `href="/f/z/docs/manual.pdf#page=2"`)
}

func TestFileSorting(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	base := time.Now().Add(-time.Hour)
	for i, name := range []string{"b.txt", "c.txt", "a.txt"} { // a is newest
		p := filepath.Join(dir, "z/sort", name)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte("x"), 0o644)
		mt := base.Add(time.Duration(i) * time.Minute)
		os.Chtimes(p, mt, mt)
	}
	os.MkdirAll(filepath.Join(dir, "z/sort/sub"), 0o755)
	// notes sort by article name, not file name: "Zeta" (a.zortex) after "Alpha" (z.zortex)
	for name, content := range map[string]string{"z/sort2/a.zortex": "@@Zeta\n", "z/sort2/z.zortex": "@@Alpha\n", "z/sort2/m.pdf": "%PDF"} {
		p := filepath.Join(dir, name)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(content), 0o644)
	}
	s.Refresh()
	if _, _, b := get(t, ts, "/f/z/sort2"); !(strings.Index(b, ">Alpha") < strings.Index(b, ">m.pdf<") && strings.Index(b, ">m.pdf<") < strings.Index(b, ">Zeta")) {
		t.Error("notes should sort by article name: Alpha, m.pdf, Zeta")
	}
	order := func(path string) string {
		_, _, body := get(t, ts, path)
		names := []string{"sub/", "a.txt", "b.txt", "c.txt"}
		sort.Slice(names, func(i, j int) bool {
			return strings.Index(body, ">"+names[i]+"<") < strings.Index(body, ">"+names[j]+"<")
		})
		return strings.Join(names, " ")
	}
	cases := map[string]string{
		"/f/z/sort":                         "sub/ a.txt b.txt c.txt",
		"/f/z/sort?sort=name&order=desc":    "sub/ c.txt b.txt a.txt",
		"/f/z/sort?sort=modified":           "sub/ a.txt c.txt b.txt", // newest first
		"/f/z/sort?sort=modified&order=asc": "sub/ b.txt c.txt a.txt",
	}
	for path, want := range cases {
		if got := order(path); got != want {
			t.Errorf("%s: %s, want %s", path, got, want)
		}
	}
	// headers: the active column flips, the other starts at its natural order;
	// folder links and breadcrumbs keep the order
	expect(t, ts, "/f/z/sort", 200,
		`href="/f/z/sort?order=desc&amp;sort=name">Name <span aria-hidden="true">↑</span>`,
		`href="/f/z/sort?order=desc&amp;sort=modified">Changed</a>`)
	expect(t, ts, "/f/z/sort?sort=modified", 200,
		`aria-sort="descending"`,
		`href="/f/z/sort?order=asc&amp;sort=modified">Changed <span aria-hidden="true">↓</span>`,
		`href="/f/z/sort/sub?sort=modified&amp;order=desc"`,
		`href="/f/z?sort=modified&amp;order=desc"`)
	// ?all=1 is kept when sorting, and the all toggle keeps the sort
	expect(t, ts, "/f/?all=1&sort=modified", 200, `href="/f/?all=1&amp;order=asc&amp;sort=modified"`, `href="/f/?order=desc&amp;sort=modified">Hide notes with generated names`)
}

func TestAreaAttributeTag(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	os.WriteFile(filepath.Join(dir, "z/bike.zortex"), []byte("@@Bike\n@P\n@area(4.1, 1.2/Fitness)\n\n- [ ] tune\n"), 0o644)
	s.Refresh()
	body := expect(t, ts, "/tag/area(4.1,%201.2%2FFitness)", 200, "[A/#4.1]", "[A/#1.2/:Fitness]", "4.1 Education")
	if strings.Contains(body, "Resolve [@area") {
		t.Error("area attribute offered as a tag link")
	}
	expect(t, ts, "/tag/P", 200, "Resolve [@P]")

	cases := map[string][]string{
		"3.2":         {"Areas/#3.2"},
		"1.2/Fitness": {"Areas/#1.2/:Fitness"},
		"#1/:x":       {"Areas/#1/:x"},
		"a/b/c":       {"Areas/a/b/c"},
		"1, 2 ,":      {"Areas/#1", "Areas/#2"},
	}
	for in, want := range cases {
		if got := areaDefinitions(in); strings.Join(got, "|") != strings.Join(want, "|") {
			t.Errorf("areaDefinitions(%q) = %v, want %v", in, got, want)
		}
	}
}

// doc/example is what new users try first and what the README screenshots
// show: every link in it must resolve.
func TestExampleNotes(t *testing.T) {
	s, err := New(Config{Root: "../../doc/example", Poll: -1, Logger: log.New(io.Discard, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	snap := s.current()
	if snap.notes < 8 || snap.links < 15 {
		t.Fatalf("notes %d links %d", snap.notes, snap.links)
	}
	for _, b := range snap.broken {
		t.Errorf("broken link in doc/example: %+v", b)
	}
}

func TestBareTagsLinkToTheirTable(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	note := "@@Tagged\n\n- [The Rust Book](https://doc.rust-lang.org/book) @rust @p1 @sm @2h @status(reading)\n"
	if err := os.WriteFile(filepath.Join(dir, "tagged.zortex"), []byte(note), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	page := expect(t, ts, "/n/tagged.zortex", 200,
		`<a class="attr tag" href="/link?from=tagged.zortex&amp;to=%40%5B%2A%2Frust%5D"`,
		`<span class="attr">@p1</span>`, `<span class="attr">@sm</span>`, `<span class="attr">@2h</span>`,
		`<span class="attr">@status(reading)</span>`)
	if strings.Count(page, `class="attr tag"`) != 1 {
		t.Errorf("only @rust is a tag link")
	}
	// the link opens the table of lines tagged @rust
	expect(t, ts, "/link?from=tagged.zortex&to=%40%5B%2A%2Frust%5D", 200, "The Rust Book")
}

// /broken lists the tags that go nowhere apart from the broken links.
func TestBrokenTags(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	if err := os.WriteFile(filepath.Join(dir, "tagcheck.zortex"), []byte("@@Tag check\n\n- a @[nosuchtag]\n- see [@NoSuchHeaderTag]\n- a line with @lonelytag and @p1 @2h @event @rust\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	body := expect(t, ts, "/broken", 200, `Tags that go nowhere`, `@[nosuchtag]`, `[@NoSuchHeaderTag]`, `no note has this tag`, `@lonelytag`)
	tags := body[strings.Index(body, "Tags that go nowhere"):]
	for _, attr := range []string{">@p1<", ">@2h<", ">@event<", ">@rust<"} {
		if strings.Contains(tags, attr) {
			t.Errorf("%s listed as an orphan tag", attr)
		}
	}
	links := body[:strings.Index(body, "Tags that go nowhere")]
	if strings.Contains(links, "NoSuchHeaderTag") {
		t.Error("a [@Tag] link listed with the broken links")
	}
}

// Hover cards: a note's title, path, tags, first lines and backlinks; a
// heading's own lines.
func TestHoverCard(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	_, _, body := get(t, ts, "/api/hover?rel=projects.zortex&lnum=0")
	var card hoverCard
	if err := json.Unmarshal([]byte(body), &card); err != nil {
		t.Fatal(err, body)
	}
	if card.Title == "" || card.Rel != "projects.zortex" || len(card.Lines) == 0 || card.Backlinks == 0 {
		t.Errorf("note card: %+v", card)
	}
	_, _, body = get(t, ts, "/api/hover?rel=projects.zortex&lnum=14")
	card = hoverCard{}
	_ = json.Unmarshal([]byte(body), &card)
	if !strings.Contains(card.Section, "1.4 - zortex") || len(card.Lines) == 0 || !strings.Contains(card.Lines[0], "Add research-ready references") {
		t.Errorf("heading card: %+v", card)
	}
	expect(t, ts, "/api/hover?rel=nope.zortex", 404)
	expect(t, ts, "/n/projects.zortex", 200, `/static/hover.js`)
}
