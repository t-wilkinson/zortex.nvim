package web

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestInstallableApp(t *testing.T) {
	accounts, err := ParseAccounts("me:pw\n")
	if err != nil {
		t.Fatal(err)
	}
	s, err := New(Config{Root: "../../tests/fixtures/notes", Base: "/notes", Title: "My notes and plans", Poll: -1, Accounts: accounts, Logger: log.New(io.Discard, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()
	get := func(path string, login bool) (*http.Response, string) {
		req, _ := http.NewRequest("GET", ts.URL+path, nil)
		if login {
			req.SetBasicAuth("me", "pw")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp, string(body)
	}

	// the manifest and icons need no login (an installer fetches them
	// without the browser's credentials); the manifest carries the base path
	resp, body := get("/notes/manifest.webmanifest", false)
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "application/manifest+json" {
		t.Fatalf("manifest: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	var m struct {
		Name      string `json:"name"`
		ShortName string `json:"short_name"`
		StartURL  string `json:"start_url"`
		Scope     string `json:"scope"`
		Display   string `json:"display"`
		Icons     []struct{ Src, Sizes, Purpose string }
	}
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatal(err)
	}
	if m.Name != "My notes and plans" || m.ShortName != "My notes and" || m.StartURL != "/notes/" || m.Scope != "/notes/" || m.Display != "standalone" || len(m.Icons) != 3 {
		t.Errorf("manifest: %+v", m)
	}
	for _, ic := range m.Icons {
		if !strings.HasPrefix(ic.Src, "/notes/static/icons/") {
			t.Errorf("icon: %+v", ic)
		}
		if r, _ := get(ic.Src, false); r.StatusCode != 200 || r.Header.Get("Content-Type") != "image/png" {
			t.Errorf("icon %s: %d %s", ic.Src, r.StatusCode, r.Header.Get("Content-Type"))
		}
	}

	// the service worker and the offline page are the app's: a login
	if r, _ := get("/notes/sw.js", false); r.StatusCode != http.StatusUnauthorized {
		t.Errorf("sw.js without a login: %d", r.StatusCode)
	}
	resp, body = get("/notes/sw.js", true)
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/javascript") || resp.Header.Get("Cache-Control") != "no-cache" || !strings.Contains(body, "zortex-pages-") {
		t.Errorf("sw.js: %d %v", resp.StatusCode, resp.Header)
	}
	resp, body = get("/notes/offline", true)
	if resp.StatusCode != 200 || !strings.Contains(body, `id="offline-list"`) {
		t.Errorf("offline: %d", resp.StatusCode)
	}

	// every page links the manifest and names the worker
	_, body = get("/notes/", true)
	for _, want := range []string{
		`<link rel="manifest" href="/notes/manifest.webmanifest" crossorigin="use-credentials">`,
		`data-sw="/notes/sw.js?v=`,
		`<link rel="apple-touch-icon" href="/notes/static/icons/apple-touch-icon.png?v=`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("page lacks %s", want)
		}
	}
	// nothing else opened up
	if r, _ := get("/notes/n/projects.zortex", false); r.StatusCode != http.StatusUnauthorized {
		t.Errorf("a note without a login: %d", r.StatusCode)
	}
	if r, _ := get("/notes/static/style.css", false); r.StatusCode != http.StatusUnauthorized {
		t.Errorf("static files without a login: %d", r.StatusCode)
	}
}
