package web

import (
	"context"
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
	t.Cleanup(s.clocks.Close)
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

// A notification coming due is an alert Neovim can ask for: /api/alerts
// gives the position first, then what came after it.
func TestFiredAlerts(t *testing.T) {
	s, _, ts, _ := newStateServer(t, "secret")
	alertsAt := func(q string) map[string]any {
		req, _ := http.NewRequest("GET", ts.URL+"/api/alerts"+q, nil)
		req.Header.Set("X-API-Key", "secret")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		json.NewDecoder(resp.Body).Decode(&out)
		return out
	}
	if code, _, _ := get(t, ts, "/api/alerts"); code != 401 {
		t.Errorf("no key: %d", code)
	}
	start := alertsAt("")
	if start["seq"] != float64(0) || len(start["alerts"].([]any)) != 0 {
		t.Fatalf("start: %v", start)
	}
	body := `{"user_id":"me","operation":"notify","notification":{"title":"Dentist","message":"12:00","scheduled_time":` + itoa(int(time.Now().Unix()-5)) + `}}`
	if code, out := post(t, ts, "/notify", body, map[string]string{"X-API-Key": "secret"}); code != 200 {
		t.Fatalf("notify: %d %v", code, out)
	}
	s.sender.SendDue(context.Background(), time.Now())
	got := alertsAt("?after=0")
	list := got["alerts"].([]any)
	if got["seq"] != float64(1) || len(list) != 1 || list[0].(map[string]any)["title"] != "Dentist" || list[0].(map[string]any)["kind"] != "calendar" {
		t.Fatalf("after 0: %v", got)
	}
	if again := alertsAt("?after=1"); len(again["alerts"].([]any)) != 0 {
		t.Errorf("nothing new after 1: %v", again)
	}
}

func TestCalendarFromNote(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "")
	day := time.Now().Format("2006-01-02")
	cal := "@@Calendar\n@@C\n\n" + day + ":\n09:00 - 10:00 Standup [P/#1.4 - zortex] @notify(no)\n- [x] Water plants @done(" + day + ")\n  - nested note\n12:00 Dentist @event @n(30)\n14:00 Gym\n"
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
	if len(got) != 5 {
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
	// the bell: only a written @n (every timed line notifies by default);
	// the month grid's dot: only @event
	if got[0].Notify || got[0].Event || !got[3].Notify || !got[3].Event || got[4].Notify || got[4].Event {
		t.Errorf("notify / event: %+v %+v %+v", got[0], got[3], got[4])
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
	// the Structure note's page lists the notes it doesn't reach (/graph too)
	page := expect(t, ts, "/n/structure.zortex", 200, `class="side-unlinked"`, `7 of 11 notes are not linked from Structure`)
	if !strings.Contains(page, `href="/n/okr.zortex"`) || !strings.Contains(page, `href="/n/hub.zortex`) {
		t.Errorf("structure note sidebar: %s", page)
	}
	if strings.Contains(expect(t, ts, "/n/okr.zortex", 200), "side-unlinked") {
		t.Error("only the Structure note has the sidebar")
	}
	expect(t, ts, "/", 200, `Not in Structure`, `7 of 11 notes are not linked from Structure`)

	// /broken: the notes outside the structure that no other note links
	// either; the ones a note links are only counted
	os.WriteFile(filepath.Join(dir, "lonely.zortex"), []byte("@@Lonely\n\nNobody links here, not even [Lonely] itself counts.\n"), 0o644)
	s.Refresh()
	broken := expect(t, ts, "/broken", 200, `id="orphans"`, `href="/n/lonely.zortex"`, `Lonely`, `linked from a note but not from the structure`)
	orphans := broken[strings.Index(broken, `id="orphans"`):]
	orphans = orphans[:strings.Index(orphans, `</table>`)]
	for _, reached := range []string{"projects.zortex", "calendar.zortex", "hub.zortex", "structure.zortex"} {
		if strings.Contains(orphans, `/n/`+reached+`"`) {
			t.Errorf("%s is reached but listed as an orphan", reached)
		}
	}
}

func TestOrphansWithoutStructure(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	os.WriteFile(filepath.Join(dir, "lonely.zortex"), []byte("@@Lonely\n\nNobody links here.\n"), 0o644)
	s.Refresh()
	page := expect(t, ts, "/broken", 200, `there is no Structure note yet`, `href="/n/lonely.zortex"`)
	if strings.Contains(page, "linked from a note but not from the structure") {
		t.Error("no structure: no count of notes outside it")
	}
}

func TestXPSummary(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "k")
	expect(t, ts, "/api/xp", 200, `"available":false`)
	home := expect(t, ts, "/", 200, `id="xp"`, `static/home.js`)
	if !strings.Contains(home, `id="xp" aria-labelledby="xp-title" hidden`) {
		t.Error("the XP panel starts hidden")
	}
	body := `{"version":2,"generated":"2026-10-12T15:00:00Z","season":{"name":"Q4","progress":0.4,"tier":"Bronze"},"today":36,"daily":[]}`
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

func TestHTMLScripts(t *testing.T) {
	s, dir, _, _ := newStateServer(t, "")
	os.WriteFile(filepath.Join(dir, "z/docs/pic.svg"), []byte("<svg/>"), 0o644)
	s.cfg.HTMLScripts = true
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)

	expect(t, ts, "/f/z/docs/page.html", 200, `sandbox="allow-scripts" title="page.html"`)
	if _, h, _ := get(t, ts, "/raw/z/docs/page.html"); h.Get("Content-Security-Policy") != "sandbox allow-scripts" {
		t.Errorf("html CSP %q", h.Get("Content-Security-Policy"))
	}
	if _, h, _ := get(t, ts, "/raw/z/docs/pic.svg"); h.Get("Content-Security-Policy") != "sandbox" {
		t.Errorf("svg CSP %q", h.Get("Content-Security-Policy"))
	}

	// a sandboxed page's POSTs are refused; the site's own go through
	if code, _ := post(t, ts, "/api/pomodoro/start", "", map[string]string{"Origin": "null"}); code != http.StatusForbidden {
		t.Errorf("POST from a sandboxed page: %d", code)
	}
	if code, _ := post(t, ts, "/api/pomodoro/start", "", map[string]string{"Origin": ts.URL}); code != http.StatusOK {
		t.Errorf("POST from the site: %d", code)
	}
}

// Results opened from the search page go through /search/open, which keeps
// them in -data/search_history.json (never the notes' .z/) and ranks them
// higher next time.
func TestSearchHistory(t *testing.T) {
	s, dir, ts, _ := newStateServer(t, "")
	body := expect(t, ts, "/search?q=zortex", 200, `/search/open?lnum=`)
	_ = body
	code, hdr, _ := get(t, ts, "/search/open?rel=projects.zortex&lnum=14&section=1")
	if code != http.StatusFound || hdr.Get("Location") != "/n/projects.zortex#L14" {
		t.Fatalf("open: %d %s", code, hdr.Get("Location"))
	}
	if s.history.Opened("projects.zortex", time.Now()) < 0.99 {
		t.Error("not recorded")
	}
	if _, err := os.Stat(filepath.Join(s.cfg.DataDir, "search_history.json")); err != nil {
		t.Errorf("history file: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, ".z", "search_history.json")); err == nil {
		t.Error("the web app wrote the notes' search history")
	}
	expect(t, ts, "/search/open?rel=nope.zortex&lnum=1", 404)
}
