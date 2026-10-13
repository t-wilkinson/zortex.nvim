package web

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// stream reads server-sent events ("kind data") from /api/events.
func stream(t *testing.T, url string) (<-chan string, func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, "GET", url+"/api/events", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type %q", ct)
	}
	out := make(chan string, 32)
	go func() {
		defer resp.Body.Close()
		sc := bufio.NewScanner(resp.Body)
		kind := ""
		for sc.Scan() {
			line := sc.Text()
			switch {
			case strings.HasPrefix(line, "event: "):
				kind = line[7:]
			case strings.HasPrefix(line, "data: "):
				out <- kind + " " + line[6:]
			}
		}
		close(out)
	}()
	return out, cancel
}

func next(t *testing.T, ch <-chan string, kind string) string {
	t.Helper()
	timeout := time.After(3 * time.Second)
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				t.Fatalf("stream closed waiting for %s", kind)
			}
			if strings.HasPrefix(ev, kind+" ") {
				return ev
			}
		case <-timeout:
			t.Fatalf("no %s event", kind)
		}
	}
}

func waitSubscribers(t *testing.T, s *Server, n int) {
	t.Helper()
	for i := 0; i < 100 && s.events.count() < n; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	if s.events.count() < n {
		t.Fatalf("%d subscribers", s.events.count())
	}
}

func TestEvents(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "")
	s.cfg.Writable = true
	ch, stop := stream(t, ts.URL)
	defer stop()
	waitSubscribers(t, s, 1)

	// a note changed on disk (Syncthing), seen by the rescan
	path := filepath.Join(dir, "flipping.zortex")
	raw, _ := os.ReadFile(path)
	later := time.Now().Add(2 * time.Second)
	os.WriteFile(path, append(raw, []byte("- synced line\n")...), 0o644)
	os.Chtimes(path, later, later)
	s.Refresh()
	if ev := next(t, ch, "notes"); !strings.Contains(ev, `"flipping.zortex"`) {
		t.Fatalf("notes event: %s", ev)
	}
	// the page fetches the new note
	code, out := getJSON(t, ts, "/api/note?rel=flipping.zortex")
	if code != 200 || !strings.Contains(out["body"].(string), "synced line") || out["mod"] == nil || out["src"] == nil {
		t.Fatalf("/api/note: %d %v", code, out)
	}
	if code, _ := getJSON(t, ts, "/api/note?rel=../etc/passwd"); code != 404 {
		t.Fatalf("/api/note outside: %d", code)
	}

	// an edit from the web
	lines := readLines(t, path)
	n := lineOf(t, lines, "synced line")
	postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": n, "expect": lines[n-1], "op": "done"})
	next(t, ch, "notes")

	// the pomodoro clock
	post(t, ts, "/api/pomodoro/start", "{}", map[string]string{"Content-Type": "application/json"})
	next(t, ch, "pomodoro")

	// a new XP summary, posted or synced
	post(t, ts, "/api/xp", `{"generated":"2026-10-12T10:00:00Z"}`, map[string]string{"Content-Type": "application/json"})
	next(t, ch, "xp")
	os.MkdirAll(filepath.Join(dir, ".z"), 0o755)
	s.Refresh() // learns there's no file yet
	os.WriteFile(filepath.Join(dir, ".z", xpFile), []byte(`{"generated":"2026-10-12T11:00:00Z"}`), 0o644)
	s.Refresh()
	next(t, ch, "xp")

	// shutdown ends the stream
	s.events.close()
	for range ch {
	}
}

func getJSON(t *testing.T, ts *httptest.Server, path string) (int, map[string]any) {
	t.Helper()
	resp, err := ts.Client().Get(ts.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}
