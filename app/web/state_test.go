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
	"sync"
	"testing"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/alerts"
)

// published collects what the ntfy stub received.
type published struct {
	mu   sync.Mutex
	msgs []map[string]any
}

func (p *published) list() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.msgs...)
}

// newStateServer: the test server with a data dir and an ntfy stub.
func newStateServer(t *testing.T, apiKey string) (*Server, string, *httptest.Server, *published) {
	t.Helper()
	s, dir, ts := newTestServer(t, "")
	pub := &published{}
	ntfy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		_ = json.NewDecoder(r.Body).Decode(&m)
		pub.mu.Lock()
		pub.msgs = append(pub.msgs, m)
		pub.mu.Unlock()
	}))
	t.Cleanup(ntfy.Close)
	s.cfg.DataDir = t.TempDir()
	s.cfg.Ntfy = &alerts.Ntfy{URL: ntfy.URL, Topic: "zortex"}
	s.cfg.APIKey = apiKey
	s.cfg.Logger = log.New(io.Discard, "", 0)
	if err := s.openState(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.pomo.Close)
	return s, dir, ts, pub
}

func post(t *testing.T, ts *httptest.Server, path, body string, header map[string]string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest("POST", ts.URL+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestNotifyAPI(t *testing.T) {
	_, _, ts, _ := newStateServer(t, "secret")
	at := time.Now().Add(time.Hour).Unix()
	body := `{"user_id":"me","operation":"sync","notifications":[{"title":"Dentist","message":"-","scheduled_time":` + itoa(int(at)) + `,"deduplication_key":"cal_1","entry_id":"Dentist"}]}`
	if code, _ := post(t, ts, "/notify", body, nil); code != 401 {
		t.Fatalf("no key: %d", code)
	}
	code, out := post(t, ts, "/notify", body, map[string]string{"X-API-Key": "secret"})
	if code != 200 || out["added"] != float64(1) {
		t.Fatalf("sync: %d %v", code, out)
	}
	_, out = post(t, ts, "/notify", body, map[string]string{"X-API-Key": "secret"})
	if out["unchanged"] != true {
		t.Fatalf("second sync should be unchanged: %v", out)
	}
	req, _ := http.NewRequest("GET", ts.URL+"/pending?user_id=me", nil)
	req.Header.Set("X-API-Key", "secret")
	resp, _ := http.DefaultClient.Do(req)
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(raw), `"count":1`) || !strings.Contains(string(raw), "Dentist") {
		t.Fatalf("pending: %s", raw)
	}
	expect(t, ts, "/api/summary", 200, `"pending_count":1`, `Dentist`)
}

func TestCalendarFromNote(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "")
	day := time.Now().Format("2006-01-02")
	cal := "@@Calendar\n@@C\n\n" + day + ":\n09:00 - 10:00 Standup [P/#1.4 - zortex] @notify(no)\n- [x] Water plants @done(" + day + ")\n  - nested note\n"
	if err := os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte(cal), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	raw := expect(t, ts, "/api/calendar?from="+day+"&to="+day, 200)
	var out struct {
		Days map[string][]calEntry `json:"days"`
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}
	got := out.Days[day]
	if len(got) != 3 {
		t.Fatalf("entries: %+v", got)
	}
	if got[0].Time != "09:00" || got[0].End != "10:00" || got[0].Text != "Standup [P/#1.4 - zortex]" || strings.Contains(got[0].HTML, "notify") || !strings.Contains(got[0].HTML, `href="/n/projects.zortex`) {
		t.Errorf("timed entry: %+v", got[0])
	}
	if !got[1].Task || !got[1].Done || got[1].Text != "Water plants" {
		t.Errorf("task entry: %+v", got[1])
	}
	if got[2].Depth != 1 {
		t.Errorf("nested entry: %+v", got[2])
	}
}

func TestPomodoroAPI(t *testing.T) {
	_, _, ts, pub := newStateServer(t, "")
	expect(t, ts, "/api/pomodoro", 200, `"phase":"idle"`, `"enabled":true`, `"ntfy":true`)
	// not JSON: refused (a cross-site form could send this)
	resp, _ := http.Post(ts.URL+"/api/pomodoro/start", "application/x-www-form-urlencoded", strings.NewReader(""))
	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("form post: %d", resp.StatusCode)
	}
	code, out := post(t, ts, "/api/pomodoro/start", "{}", nil)
	if code != 200 || out["phase"] != "work" || out["running"] != true || out["next_alarm"] == nil {
		t.Fatalf("start: %d %v", code, out)
	}
	code, out = post(t, ts, "/api/pomodoro/pause", "{}", nil)
	if code != 200 || out["running"] != false {
		t.Fatalf("pause: %d %v", code, out)
	}
	code, out = post(t, ts, "/api/pomodoro/settings", `{"work":50}`, nil)
	if code != 200 || out["settings"].(map[string]any)["work"] != float64(50) || out["settings"].(map[string]any)["short_break"] != float64(5) {
		t.Fatalf("settings: %d %v", code, out)
	}
	if code, _ = post(t, ts, "/api/pomodoro/settings", `{"work":0}`, nil); code != http.StatusConflict {
		t.Fatalf("bad settings: %d", code)
	}
	post(t, ts, "/api/pomodoro/skip", "{}", nil) // work -> break
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && len(pub.list()) < 2 {
		time.Sleep(20 * time.Millisecond)
	}
	var tags []string
	for _, m := range pub.list() {
		for _, tg := range m["tags"].([]any) {
			tags = append(tags, tg.(string))
		}
	}
	joined := strings.Join(tags, ",")
	if !strings.Contains(joined, "pomodoro-work-start") || !strings.Contains(joined, "pomodoro-break-start") {
		t.Fatalf("ntfy tags: %v", joined)
	}
}

func TestStructure(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	os.WriteFile(filepath.Join(dir, "structure.zortex"), []byte("@@Structure\n@@S\n\n- [Projects]\n- [Areas]\n- [Hub]\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "hub.zortex"), []byte("@@Hub\n@Structure\n\n- [Calendar]\n"), 0o644)
	s.Refresh()
	raw := expect(t, ts, "/api/structure", 200, `"structure.zortex"`, `"hub.zortex"`)
	var out struct {
		Unlinked []struct{ Rel string } `json:"unlinked"`
	}
	json.Unmarshal([]byte(raw), &out)
	var rels []string
	for _, u := range out.Unlinked {
		rels = append(rels, u.Rel)
	}
	got := strings.Join(rels, ",")
	for _, linked := range []string{"projects.zortex", "areas.zortex", "calendar.zortex", "hub.zortex", "structure.zortex", "archive.projects.zortex"} {
		if strings.Contains(got, linked) {
			t.Errorf("%s listed as unlinked: %s", linked, got)
		}
	}
	if !strings.Contains(got, "okr.zortex") || !strings.Contains(got, "z/garden.zortex") {
		t.Errorf("unlinked: %s", got)
	}
	// /structure is the Structure note, rendered like any note, with the
	// notes it doesn't reach in the sidebar
	page := expect(t, ts, "/structure", 200, `<h1>Structure</h1>`, `class="side-unlinked"`, `4 of 8 notes are not linked from Structure`, `href="/structure" aria-current="page"`)
	if !strings.Contains(page, `href="/n/okr.zortex"`) || !strings.Contains(page, `href="/n/hub.zortex`) {
		t.Errorf("structure page body or sidebar: %s", page)
	}
	expect(t, ts, "/n/structure.zortex", 200, `class="side-unlinked"`)
	if strings.Contains(expect(t, ts, "/n/okr.zortex", 200), "side-unlinked") {
		t.Error("only the Structure note has the sidebar")
	}
	expect(t, ts, "/", 200, `Not in Structure`, `4 of 8 notes are not linked from Structure`)
}

func TestXPSummary(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "k")
	expect(t, ts, "/api/xp", 200, `"available":false`)
	home := expect(t, ts, "/", 200, `id="xp"`, `static/home.js`)
	if !strings.Contains(home, `id="xp" aria-labelledby="xp-title" hidden`) {
		t.Error("the XP panel starts hidden")
	}
	body := `{"version":1,"generated":"2026-10-12T15:00:00Z","season":{"name":"Q4","level":2},"today":36,"daily":[]}`
	if code, _ := post(t, ts, "/api/xp", body, nil); code != 401 {
		t.Fatalf("no key: %d", code)
	}
	if code, _ := post(t, ts, "/api/xp", body, map[string]string{"X-API-Key": "k"}); code != 200 {
		t.Fatalf("post: %d", code)
	}
	expect(t, ts, "/api/xp", 200, `"name":"Q4"`, `"available":true`)
	// persisted in the data dir
	if raw, err := os.ReadFile(filepath.Join(s.cfg.DataDir, "xp_summary.json")); err != nil || !strings.Contains(string(raw), "Q4") {
		t.Fatalf("persisted: %v %s", err, raw)
	}
	// a newer copy synced into the notes folder wins; an older one doesn't
	os.MkdirAll(filepath.Join(dir, ".z"), 0o755)
	os.WriteFile(filepath.Join(dir, ".z", "xp_summary.json"), []byte(`{"version":1,"generated":"2026-10-12T14:00:00Z","season":{"name":"Old"}}`), 0o644)
	expect(t, ts, "/api/xp", 200, `"name":"Q4"`)
	later := time.Now().Add(time.Second)
	os.WriteFile(filepath.Join(dir, ".z", "xp_summary.json"), []byte(`{"version":1,"generated":"2026-10-12T16:00:00Z","season":{"name":"Synced"}}`), 0o644)
	os.Chtimes(filepath.Join(dir, ".z", "xp_summary.json"), later, later)
	expect(t, ts, "/api/xp", 200, `"name":"Synced"`)
	// not JSON
	if code, _ := post(t, ts, "/api/xp", "nope", map[string]string{"X-API-Key": "k"}); code != 400 {
		t.Fatalf("bad body: %d", code)
	}
}

func TestXPSummaryWithoutDataDir(t *testing.T) {
	_, dir, ts := newTestServer(t, "")
	os.MkdirAll(filepath.Join(dir, ".z"), 0o755)
	os.WriteFile(filepath.Join(dir, ".z", "xp_summary.json"), []byte(`{"version":1,"generated":"2026-10-12T16:00:00Z","today":5}`), 0o644)
	expect(t, ts, "/api/xp", 200, `"today":5`)
	// and it isn't reachable as a file
	if code, _, _ := get(t, ts, "/raw/.z/xp_summary.json"); code != 404 {
		t.Errorf("hidden state served: %d", code)
	}
}
