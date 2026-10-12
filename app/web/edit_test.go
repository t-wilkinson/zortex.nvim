package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func writableServer(t *testing.T) (*Server, string, *httptest.Server) {
	t.Helper()
	s, dir, ts, _ := newStateServer(t, "")
	s.cfg.Writable = true
	return s, dir, ts
}

func postJSON(t *testing.T, url, path string, body any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(body)
	resp, err := http.Post(url+path, "application/json", strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
}

func lineOf(t *testing.T, lines []string, prefix string) int {
	t.Helper()
	for i, l := range lines {
		if strings.Contains(l, prefix) {
			return i + 1
		}
	}
	t.Fatalf("no line with %q", prefix)
	return 0
}

func TestEditReadOnly(t *testing.T) {
	_, _, ts, _ := newStateServer(t, "")
	code, out := postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": 12, "op": "toggle"})
	if code != http.StatusForbidden || !strings.Contains(out["error"].(string), "-writable") {
		t.Fatalf("read-only: %d %v", code, out)
	}
	if strings.Contains(expect(t, ts, "/n/flipping.zortex", 200), "edit-toggle") {
		t.Error("read-only note page offers editing")
	}
}

func TestEditToggleAndConflict(t *testing.T) {
	_, dir, ts := writableServer(t)
	url := ts.URL
	path := filepath.Join(dir, "flipping.zortex")
	lines := readLines(t, path)
	n := lineOf(t, lines, "Pull engine")
	before := lines[n-1]

	code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": n, "expect": before, "op": "toggle"})
	if code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	today := time.Now().Format("2006-01-02")
	got := readLines(t, path)[n-1]
	if !regexp.MustCompile(`^- \[x\] Pull engine @size\(xl\) @id\(\w{5}\) @done\(` + today + `\)$`).MatchString(got) {
		t.Fatalf("toggled line: %q", got)
	}
	if !strings.Contains(out["body"].(string), `class="ln item task done" id="L`+itoa(n)) {
		t.Error("response carries the re-rendered note")
	}
	// the page's copy is stale now: refused, file untouched, latest note sent
	code, out = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": n, "expect": before, "op": "toggle"})
	if code != http.StatusConflict || out["body"] == nil {
		t.Fatalf("stale edit: %d %v", code, out)
	}
	if readLines(t, path)[n-1] != got {
		t.Fatal("a stale edit changed the file")
	}
	// back to open: @done removed, @id kept
	code, _ = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": n, "expect": got, "op": "toggle"})
	back := readLines(t, path)[n-1]
	if code != 200 || strings.Contains(back, "@done") || !strings.Contains(back, "@id(") || !strings.HasPrefix(back, "- [ ] ") {
		t.Fatalf("toggle back: %d %q", code, back)
	}
}

func TestEditSetInsertDelete(t *testing.T) {
	_, dir, ts := writableServer(t)
	url := ts.URL
	path := filepath.Join(dir, "flipping.zortex")
	lines := readLines(t, path)
	h := lineOf(t, lines, "# Subaru outback")

	// insert a task under the heading
	code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": h, "expect": lines[h-1], "op": "insert", "kind": "task", "text": "Order gaskets"})
	if code != 200 || out["lnum"].(float64) != float64(h+1) {
		t.Fatalf("insert: %d %v", code, out)
	}
	lines = readLines(t, path)
	if !regexp.MustCompile(`^- \[ \] Order gaskets @id\(\w{5}\)$`).MatchString(lines[h]) {
		t.Fatalf("inserted: %q", lines[h])
	}
	// edit its text: the marker, checkbox stay; the new text replaces the rest
	id := regexp.MustCompile(`@id\(\w+\)`).FindString(lines[h])
	code, _ = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": h + 1, "expect": lines[h], "op": "set", "text": "Order head gaskets @p1"})
	lines = readLines(t, path)
	if code != 200 || lines[h] != "- [ ] Order head gaskets @p1 "+id {
		t.Fatalf("set keeps @id: %d %q", code, lines[h])
	}
	// a note line, then delete it
	code, _ = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": h + 1, "expect": lines[h], "op": "insert", "kind": "note", "text": "Ask about torque specs"})
	lines = readLines(t, path)
	if code != 200 || lines[h+1] != "- Ask about torque specs" {
		t.Fatalf("note: %d %q", code, lines[h+1])
	}
	count := len(lines)
	code, _ = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": h + 2, "expect": lines[h+1], "op": "delete"})
	if code != 200 || len(readLines(t, path)) != count-1 {
		t.Fatalf("delete: %d", code)
	}
	// structure and header are off limits
	code, out = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": h, "expect": lines[h-1], "op": "toggle"})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("heading toggled: %d %v", code, out)
	}
	code, _ = postJSON(t, url, "/api/edit", map[string]any{"rel": "flipping.zortex", "lnum": 1, "expect": "@@Flipping", "op": "delete"})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("header deleted: %d", code)
	}
	// nothing outside the folder
	code, _ = postJSON(t, url, "/api/edit", map[string]any{"rel": "../x.zortex", "lnum": 1, "op": "delete"})
	if code != http.StatusNotFound {
		t.Fatalf("outside: %d", code)
	}
}

func TestEditKeepsLineEndings(t *testing.T) {
	s, dir, ts := writableServer(t)
	url := ts.URL
	path := filepath.Join(dir, "crlf.zortex")
	os.WriteFile(path, []byte("@@Win\r\n\r\n- [ ] One\r\n- [ ] Two\r\n"), 0o640)
	s.Refresh()
	code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "crlf.zortex", "lnum": 3, "expect": "- [ ] One", "op": "done"})
	if code != 200 {
		t.Fatalf("%d %v", code, out)
	}
	raw, _ := os.ReadFile(path)
	if !strings.HasSuffix(string(raw), "- [ ] Two\r\n") || strings.Count(string(raw), "\r\n") != 4 || strings.Contains(strings.ReplaceAll(string(raw), "\r\n", ""), "\n") {
		t.Fatalf("line endings: %q", raw)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o640 {
		t.Fatalf("mode: %v", st.Mode())
	}
	if m, _ := filepath.Glob(filepath.Join(dir, ".syncthing.*")); len(m) > 0 {
		t.Fatalf("temporary files left: %v", m)
	}
}

func TestInboxAndPending(t *testing.T) {
	s, dir, ts := writableServer(t)
	url := ts.URL
	code, out := postJSON(t, url, "/api/inbox", map[string]any{"text": "Call the junkyard", "kind": "task"})
	if code != 200 {
		t.Fatalf("inbox: %d %v", code, out)
	}
	lines := readLines(t, filepath.Join(dir, "inbox.zortex"))
	if lines[0] != "@@Inbox" || lines[1] != "" || !regexp.MustCompile(`^- \[ \] Call the junkyard @id\(\w{5}\)$`).MatchString(lines[2]) {
		t.Fatalf("new inbox: %q", lines)
	}
	postJSON(t, url, "/api/inbox", map[string]any{"text": "Torque spec is 22 ft-lb", "kind": "note"})
	lines = readLines(t, filepath.Join(dir, "inbox.zortex"))
	if lines[len(lines)-1] != "- Torque spec is 22 ft-lb" {
		t.Fatalf("note: %q", lines)
	}

	// complete it on the web: pending until Neovim publishes a newer summary
	n := 3
	postJSON(t, url, "/api/edit", map[string]any{"rel": "inbox.zortex", "lnum": n, "expect": lines[n-1], "op": "done"})
	var x map[string]any
	_ = json.Unmarshal([]byte(expect(t, ts, "/api/xp", 200)), &x)
	if x["pending_web"].(float64) != 1 || x["pending_titles"].([]any)[0] != "Call the junkyard" {
		t.Fatalf("pending: %v", x)
	}
	later := time.Now().Add(time.Minute).UTC().Format(time.RFC3339)
	postJSON(t, url, "/api/xp", map[string]any{"version": 1, "generated": later})
	_ = json.Unmarshal([]byte(expect(t, ts, "/api/xp", 200)), &x)
	if x["pending_web"].(float64) != 0 {
		t.Fatalf("counted: %v", x)
	}
	_ = s
}

func TestCalendarSourcesWhenWritable(t *testing.T) {
	s, dir, ts := writableServer(t)
	day := time.Now().Format("2006-01-02")
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte("@@Calendar\n\n"+day+":\n- [ ] Buy oil\n"), 0o644)
	s.Refresh()
	raw := expect(t, ts, "/api/calendar?from="+day+"&to="+day, 200, `"writable":true`, `"src":"- [ ] Buy oil"`, `"rel":"calendar.zortex"`)
	_ = raw
	home := expect(t, ts, "/", 200, `id="inbox-form"`)
	_ = home
	expect(t, ts, "/n/calendar.zortex", 200, `id="edit-toggle"`, `id="note-src"`, `static/edit.js`)
}
