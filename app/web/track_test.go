package web

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/tracker"
)

type fakeNow struct {
	mu sync.Mutex
	t  time.Time
}

func (f *fakeNow) now() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.t }
func (f *fakeNow) add(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

func TestTrackTime(t *testing.T) {
	s, dir, ts := writableServer(t)
	js := map[string]string{"Content-Type": "application/json"}
	// a calendar entry running all day, linking a task
	today := time.Now().Format("2006-01-02")
	cal := "@@Calendar\n\n" + today + ":\n00:00 Work on [P/#1.4 - zortex/-Improve website]\n"
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte(cal), 0o644)
	s.Refresh()
	clock := &fakeNow{t: time.Now()}
	tr, err := tracker.OpenAt(filepath.Join(t.TempDir(), "track.json"), s.writeSpent, clock.now)
	if err != nil {
		t.Fatal(err)
	}
	tr.OnWrite = s.logTrack
	s.track = tr

	_, out := getJSON(t, ts, "/api/track")
	task, _ := out["task"].(map[string]any)
	if out["enabled"] != true || out["mode"] != "calendar" || task == nil || task["text"] != "Improve website" {
		t.Fatalf("follows the calendar's linked task: %v", out)
	}
	// the stopwatch runs 5 minutes, then pauses: 5m on the task
	post(t, ts, "/api/clocks/stopwatch/start", "{}", js)
	clock.add(5 * time.Minute)
	post(t, ts, "/api/clocks/stopwatch/pause", "{}", js)
	lines := readLines(t, filepath.Join(dir, "projects.zortex"))
	line := lines[lineOf(t, lines, "Improve website")-1]
	if !strings.Contains(line, "@spent(5m)") {
		t.Fatalf("not written: %q", line)
	}
	_, out = getJSON(t, ts, "/api/track")
	if out["task"].(map[string]any)["spent_min"].(float64) != 5 {
		t.Fatalf("spent: %v", out["task"])
	}
	// and again: it adds up
	post(t, ts, "/api/clocks/stopwatch/start", "{}", js)
	clock.add(80 * time.Minute)
	post(t, ts, "/api/clocks/stopwatch/reset", "{}", js)
	lines = readLines(t, filepath.Join(dir, "projects.zortex"))
	if l := lines[lineOf(t, lines, "Improve website")-1]; !strings.Contains(l, "@spent(1h25m)") {
		t.Fatalf("not added up: %q", l)
	}

	// pick another task by hand, from the picker
	_, found := getJSON(t, ts, "/api/track/tasks?q=change%20sizes")
	tasks := found["tasks"].([]any)
	if len(tasks) != 1 {
		t.Fatalf("search: %v", found)
	}
	pick := tasks[0].(map[string]any)
	n := int(pick["lnum"].(float64))
	code, out := post(t, ts, "/api/track/pin", `{"rel":"projects.zortex","lnum":`+strconv.Itoa(n)+`}`, js)
	if code != 200 || out["mode"] != "pinned" || out["task"].(map[string]any)["text"] != "Change task sizes" || out["calendar"] == nil {
		t.Fatalf("pin: %d %v", code, out)
	}
	// under a minute, then switching back: nothing written
	post(t, ts, "/api/clocks/stopwatch/start", "{}", js)
	clock.add(40 * time.Second)
	post(t, ts, "/api/track/follow", "{}", js)
	lines = readLines(t, filepath.Join(dir, "projects.zortex"))
	if l := lines[n-1]; strings.Contains(l, "@spent") {
		t.Fatalf("40 s written: %q", l)
	}
	post(t, ts, "/api/clocks/stopwatch/reset", "{}", js)

	// a log of what was written
	raw, _ := os.ReadFile(filepath.Join(s.cfg.DataDir, trackLog))
	if strings.Count(string(raw), "\n") != 2 {
		t.Fatalf("log: %s", raw)
	}
	// read-only servers don't track
	s.cfg.Writable = false
	if _, out := getJSON(t, ts, "/api/track"); out["enabled"] != false {
		t.Fatalf("read-only: %v", out)
	}
}

func TestDurations(t *testing.T) {
	for in, want := range map[string]float64{"1h25m": 85, "45m": 45, "2h": 120, "1.5h": 90, "1d": 1440} {
		if got, ok := parseMinutes(in); !ok || got != want {
			t.Errorf("parseMinutes(%q) = %v", in, got)
		}
	}
	if _, ok := parseMinutes("soon"); ok {
		t.Error("parsed nonsense")
	}
	for in, want := range map[int]string{85: "1h25m", 45: "45m", 120: "2h", 0: "0m"} {
		if got := formatMinutes(in); got != want {
			t.Errorf("formatMinutes(%d) = %q", in, got)
		}
	}
}
