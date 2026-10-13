package web

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLogin(t *testing.T) {
	accounts, err := ParseAccounts("# who may read\nme:s3cret:with:colons\n\nyou:pw\n")
	if err != nil || len(accounts) != 2 || accounts[0].Password != "s3cret:with:colons" {
		t.Fatalf("parse: %v %+v", err, accounts)
	}
	if _, err := ParseAccounts("nopassword\n"); err == nil {
		t.Fatal("accepted a line without a password")
	}
	s, err := New(Config{Root: "../../tests/fixtures/notes", Poll: -1, APIKey: "k", Accounts: accounts, Logger: log.New(io.Discard, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()
	do := func(path string, set func(*http.Request)) int {
		req, _ := http.NewRequest("GET", ts.URL+path, nil)
		if set != nil {
			set(req)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == 401 && !strings.Contains(resp.Header.Get("WWW-Authenticate"), "Basic") {
			t.Errorf("401 without a Basic challenge")
		}
		return resp.StatusCode
	}
	if code := do("/", nil); code != 401 {
		t.Errorf("no login: %d", code)
	}
	if code := do("/n/projects.zortex", func(r *http.Request) { r.SetBasicAuth("me", "wrong") }); code != 401 {
		t.Errorf("wrong password: %d", code)
	}
	if code := do("/n/projects.zortex", func(r *http.Request) { r.SetBasicAuth("you", "pw") }); code != 200 {
		t.Errorf("login: %d", code)
	}
	if code := do("/healthz", nil); code != 200 {
		t.Errorf("health check needs no login: %d", code)
	}
	if code := do("/api/pomodoro", func(r *http.Request) { r.Header.Set("X-API-Key", "k") }); code != 200 {
		t.Errorf("Neovim's API key: %d", code)
	}
	if code := do("/api/pomodoro", func(r *http.Request) { r.Header.Set("X-API-Key", "nope") }); code != 401 {
		t.Errorf("bad API key: %d", code)
	}
}
