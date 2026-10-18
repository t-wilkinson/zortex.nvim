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
	return streamPath(t, url, "/api/events")
}

// streamPath is stream from path ("/api/events?client=a").
func streamPath(t *testing.T, url, path string) (<-chan string, func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, "GET", url+path, nil)
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

func TestClocksAPI(t *testing.T) {
	s, _, ts, pub := newStateServer(t, "")
	ch, stop := stream(t, ts.URL)
	defer stop()
	waitSubscribers(t, s, 1)
	js := map[string]string{"Content-Type": "application/json"}

	code, out := post(t, ts, "/api/clocks/timers", `{"label":"Tea","seconds":1}`, js)
	if code != 200 || len(out["timers"].([]any)) != 1 {
		t.Fatalf("timer: %d %v", code, out)
	}
	next(t, ch, "clocks")
	// it ends on its own: an event for open pages and an ntfy message
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && len(pub.list()) == 0 {
		time.Sleep(20 * time.Millisecond)
	}
	msgs := pub.list()
	if len(msgs) != 1 || msgs[0]["title"] != "Timer: Tea" {
		t.Fatalf("ntfy: %v", msgs)
	}
	id := out["timers"].([]any)[0].(map[string]any)["id"].(string)
	if code, _ := post(t, ts, "/api/clocks/timers/"+id+"/remove", `{}`, js); code != 200 {
		t.Fatalf("remove: %d", code)
	}
	if code, _ := post(t, ts, "/api/clocks/timers/nope/pause", `{}`, js); code != 404 {
		t.Fatalf("unknown: %d", code)
	}

	code, out = post(t, ts, "/api/clocks/alarms", `{"label":"Wake","time":"7:30","repeat":"daily"}`, js)
	alarms := out["alarms"].([]any)
	if code != 200 || alarms[0].(map[string]any)["time"] != "07:30" {
		t.Fatalf("alarm: %d %v", code, out)
	}
	if code, _ := post(t, ts, "/api/clocks/alarms", `{"time":"9pm"}`, js); code != 422 {
		t.Fatalf("bad alarm time: %d", code)
	}
	code, out = post(t, ts, "/api/clocks/stopwatch/start", `{}`, js)
	if code != 200 || !out["stopwatch"].(map[string]any)["running"].(bool) {
		t.Fatalf("stopwatch: %d %v", code, out)
	}
	// not JSON: refused (a cross-site form can't drive the clocks)
	if code, _ := post(t, ts, "/api/clocks/stopwatch/reset", `x`, map[string]string{"Content-Type": "text/plain"}); code != http.StatusUnsupportedMediaType {
		t.Fatalf("form post: %d", code)
	}
	code, out = getJSON(t, ts, "/api/clocks")
	if code != 200 || len(out["alarms"].([]any)) != 1 || out["ntfy"] != true {
		t.Fatalf("get: %d %v", code, out)
	}
}

func postRaw(t *testing.T, url, body string) (int, string) {
	t.Helper()
	resp, err := http.Post(url, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b strings.Builder
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		b.WriteString(sc.Text())
	}
	return resp.StatusCode, b.String()
}

func TestOpenInTab(t *testing.T) {
	s, _, ts, _ := newStateServer(t, "")
	// no tab: Neovim opens a new one
	if code, body := postRaw(t, ts.URL+"/api/open", `{"path":"/n/projects.zortex"}`); code != 200 || !strings.Contains(body, `"opened":false`) {
		t.Fatalf("no tab: %d %s", code, body)
	}
	a, stopA := streamPath(t, ts.URL, "/api/events?client=a")
	defer stopA()
	b, stopB := streamPath(t, ts.URL, "/api/events?client=b")
	defer stopB()
	waitSubscribers(t, s, 2)
	// b was focused last: it gets the path, and the request waits for its answer
	time.Sleep(5 * time.Millisecond)
	postRaw(t, ts.URL+"/api/presence", `{"client":"a"}`)
	time.Sleep(5 * time.Millisecond)
	postRaw(t, ts.URL+"/api/presence", `{"client":"b"}`)
	done := make(chan string, 1)
	go func() {
		resp, err := http.Post(ts.URL+"/api/open", "application/json", strings.NewReader(`{"path":"/n/projects.zortex#L3"}`))
		if err != nil {
			done <- err.Error()
			return
		}
		defer resp.Body.Close()
		var b strings.Builder
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			b.WriteString(sc.Text())
		}
		done <- b.String()
	}()
	ev := next(t, b, "open")
	var got struct{ Path, Token string }
	if err := json.Unmarshal([]byte(strings.TrimPrefix(ev, "open ")), &got); err != nil || got.Path != "/n/projects.zortex#L3" || got.Token == "" {
		t.Fatalf("open event: %s", ev)
	}
	if code, _ := postRaw(t, ts.URL+"/api/open/ack", `{"token":"`+got.Token+`"}`); code != 204 {
		t.Fatalf("ack: %d", code)
	}
	if body := <-done; !strings.Contains(body, `"opened":true`) {
		t.Fatalf("open: %s", body)
	}
	select {
	case ev := <-a:
		if strings.HasPrefix(ev, "open ") {
			t.Fatalf("only the latest tab opens: %s", ev)
		}
	default:
	}
	// only paths in this app
	for _, p := range []string{"https://example.com", "//example.com", "n/x"} {
		if code, _ := postRaw(t, ts.URL+"/api/open", `{"path":"`+p+`"}`); code != 400 {
			t.Errorf("%s: %d", p, code)
		}
	}
	// a form post (no JSON) can't steer a tab
	resp, err := http.Post(ts.URL+"/api/open", "application/x-www-form-urlencoded", strings.NewReader("path=/n/x"))
	if err != nil || resp.StatusCode != 415 {
		t.Errorf("form post: %v %v", err, resp)
	}
}

func TestClientAddr(t *testing.T) {
	for _, c := range []struct{ remote, xff, want string }{
		{"10.0.0.5:4000", "", "10.0.0.5"},
		{"127.0.0.1:4000", "192.168.1.20, 127.0.0.1", "192.168.1.20"},
		{"203.0.113.9:4000", "1.2.3.4", "203.0.113.9"}, // a public peer can't claim an address
	} {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.remote
		if c.xff != "" {
			r.Header.Set("X-Forwarded-For", c.xff)
		}
		if got := clientAddr(r); got != c.want {
			t.Errorf("%s %q: %s, want %s", c.remote, c.xff, got, c.want)
		}
	}
}
