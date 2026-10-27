package web

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A task completed on the web is estimated like Neovim does until Neovim
// counts it: a calendar copy weighs its project task, once.
func TestPendingXPEstimate(t *testing.T) {
	s, dir, ts := writableServer(t)
	proj := filepath.Join(dir, "projects.zortex")
	raw, _ := os.ReadFile(proj)
	os.WriteFile(proj, []byte(strings.Replace(string(raw), "- [ ] Improve website @p1 @size(xl)", "- [ ] Improve website @p1 @size(xl) @id(imp01)", 1)), 0o644)
	day := time.Now().Format("2006-01-02")
	copyLine := "- [ ] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(imp01)"
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte("@@Calendar\n\n"+day+":\n"+copyLine+"\n- [ ] Buy oil @sm\n"), 0o644)
	s.Refresh()

	xp := func() map[string]any {
		var x map[string]any
		_ = json.Unmarshal([]byte(expect(t, ts, "/api/xp", 200)), &x)
		return x
	}
	// the copy: xl (3h) x 10 XP/h = 30 (@p1 ranks it, it doesn't pay more by
	// default), titled as the project task
	if code, out := postJSON(t, ts.URL, "/api/n/calendar.zortex", map[string]any{"lnum": 4, "expect": copyLine, "op": "done"}); code != 200 {
		t.Fatalf("%d %v", code, out)
	}
	x := xp()
	if x["pending_web"].(float64) != 1 || x["pending_xp"].(float64) != 30 {
		t.Fatalf("copy: %v", x)
	}
	if task := x["pending_tasks"].([]any)[0].(map[string]any); task["title"] != "Improve website" || task["hours"].(float64) != 3 {
		t.Fatalf("task: %v", task)
	}
	// unchecking the project task itself takes it back out (same @id)
	lines := readLines(t, proj)
	for i, l := range lines {
		if strings.Contains(l, "@id(imp01)") {
			postJSON(t, ts.URL, "/api/n/projects.zortex", map[string]any{"lnum": i + 1, "expect": l, "op": "open"})
		}
	}
	if x = xp(); x["pending_web"].(float64) != 0 {
		t.Fatalf("unchecked: %v", x)
	}
	// a bare size, with Neovim's calibration from the summary (20 XP an hour)
	postJSON(t, ts.URL, "/api/xp", map[string]any{"version": 2, "generated": time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
		"calibration": map[string]any{"xp_per_hour": 20}})
	lines = readLines(t, filepath.Join(dir, "calendar.zortex"))
	postJSON(t, ts.URL, "/api/n/calendar.zortex", map[string]any{"lnum": 5, "expect": lines[4], "op": "done"})
	if x = xp(); x["pending_xp"].(float64) != 10 { // sm: 0.5h x 20
		t.Fatalf("calibrated: %v", x)
	}
	// Neovim's multipliers, when its xp.modifiers sets them, still apply
	c := calibrationOf([]byte(`{"calibration": {"priority": {"1": 1.5}}}`))
	if got := c.taskXP("xl", "1", ""); got != 45 {
		t.Fatalf("@p1 x1.5 from the summary: %v", got)
	}
}
