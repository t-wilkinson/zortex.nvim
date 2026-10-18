package web

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
)

// A project task and its calendar copies share an @id (mirrors.go).

func writeNote(t *testing.T, s *Server, dir, rel string, lines []string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, rel), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
}

// projects.zortex with an @id on "Improve website", and a calendar day.
func mirrorServer(t *testing.T, day []string) (*Server, string, *httptest.Server) {
	t.Helper()
	s, dir, ts := writableServer(t)
	proj := readLines(t, filepath.Join(dir, "projects.zortex"))
	i := lineOf(t, proj, "Improve website") - 1
	proj[i] += " @id(web01)"
	writeNote(t, s, dir, "projects.zortex", proj)
	cal := append([]string{"@@Calendar", "", today() + ":"}, day...)
	writeNote(t, s, dir, "calendar.zortex", cal)
	return s, dir, ts
}

func lineWith(t *testing.T, path, text string) (int, string) {
	t.Helper()
	lines := readLines(t, path)
	n := lineOf(t, lines, text)
	return n, lines[n-1]
}

func TestMirrorToggleBothWays(t *testing.T) {
	_, dir, ts := mirrorServer(t, []string{
		"- [ ] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(web01)",
	})
	url := ts.URL
	cal, proj := filepath.Join(dir, "calendar.zortex"), filepath.Join(dir, "projects.zortex")

	// tick the copy: the project task is done too, with the same date
	n, line := lineWith(t, cal, "@id(web01)")
	code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "calendar.zortex", "lnum": n, "expect": line, "op": "toggle"})
	if code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	if _, l := lineWith(t, proj, "Improve website"); l != "- [x] Improve website @p1 @size(xl) @id(web01) @done("+today()+")" {
		t.Fatalf("project task: %q", l)
	}
	// reopen it from the project: the copy reopens
	n, line = lineWith(t, proj, "Improve website")
	code, out = postJSON(t, url, "/api/edit", map[string]any{"rel": "projects.zortex", "lnum": n, "expect": line, "op": "toggle"})
	if code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	if _, l := lineWith(t, cal, "@id(web01)"); l != "- [ ] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(web01)" {
		t.Fatalf("copy: %q", l)
	}
}

func TestMirrorMovedCopiesStay(t *testing.T) {
	s, dir, ts := mirrorServer(t, []string{"- [ ] [P/#1.4 - zortex/-Improve website] @id(web01)"})
	url := ts.URL
	cal := filepath.Join(dir, "calendar.zortex")
	lines := readLines(t, cal)
	lines = append(lines, "", "2020-01-01:", "- [>] [P/#1.4 - zortex/-Improve website] @id(web01)")
	writeNote(t, s, dir, "calendar.zortex", lines)
	proj := filepath.Join(dir, "projects.zortex")
	n, line := lineWith(t, proj, "Improve website")
	postJSON(t, url, "/api/edit", map[string]any{"rel": "projects.zortex", "lnum": n, "expect": line, "op": "done"})
	lines = readLines(t, cal)
	if !strings.HasPrefix(lines[lineOf(t, lines, today()+":")], "- [x] [P/#1.4 - zortex/-Improve website] @id(web01) @done(") {
		t.Fatalf("copy not ticked: %q", lines)
	}
	if l := lines[lineOf(t, lines, "[>]")-1]; l != "- [>] [P/#1.4 - zortex/-Improve website] @id(web01)" {
		t.Fatalf("moved copy changed: %q", l)
	}
}

func TestMirrorReferenceLine(t *testing.T) {
	_, dir, ts := mirrorServer(t, []string{
		"09:00 [P/#1.4 - zortex]",
		"  - [./-Improve website]",
	})
	url := ts.URL
	cal, proj := filepath.Join(dir, "calendar.zortex"), filepath.Join(dir, "projects.zortex")
	// the calendar shows it as a task, open, standing for the project task
	entry := func() map[string]any {
		_, out := getJSON(t, ts, "/api/calendar?from="+today()+"&to="+today())
		for _, e := range out["days"].(map[string]any)[today()].([]any) {
			if m := e.(map[string]any); m["ref"] != nil {
				return m
			}
		}
		t.Fatalf("no reference entry: %v", out["days"])
		return nil
	}
	if e := entry(); e["task"] != true || e["done"] == true || !strings.HasPrefix(e["ref"].(string), "projects.zortex:") {
		t.Fatalf("reference: %v", e)
	}
	n, line := lineWith(t, cal, "[./-Improve website]")
	code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "calendar.zortex", "lnum": n, "expect": line, "op": "toggle"})
	if code != 200 || out["task"] == nil {
		t.Fatalf("toggle: %d %v", code, out)
	}
	if _, l := lineWith(t, proj, "Improve website"); !strings.HasPrefix(l, "- [x] Improve website") {
		t.Fatalf("project task: %q", l)
	}
	if _, l := lineWith(t, cal, "[./-Improve website]"); l != "  - [./-Improve website]" {
		t.Fatalf("the reference line changed: %q", l)
	}
	if e := entry(); e["done"] != true {
		t.Fatalf("shows the task's state: %v", e)
	}
	// the link itself renders through its parent line
	expect(t, ts, "/n/calendar.zortex", 200, `href="/n/projects.zortex#L16"`)
}

func TestMirrorShownAndProblems(t *testing.T) {
	s, dir, ts := mirrorServer(t, []string{"- [x] [P/#1.4 - zortex/-Improve website] @id(web01) @done(2026-10-14)"})
	// checked on the calendar (by hand): the project page shows it done
	expect(t, ts, "/n/projects.zortex", 200, `class="box done mirrored"`, `title="done on the calendar"`)

	// a copied project line and a copy linking another task: on /broken
	proj := readLines(t, filepath.Join(dir, "projects.zortex"))
	proj[lineOf(t, proj, "Change task sizes")-1] += " @id(web01)"
	writeNote(t, s, dir, "projects.zortex", proj)
	cal := readLines(t, filepath.Join(dir, "calendar.zortex"))
	cal = append(cal, "- [ ] [P/#1.4 - zortex/-Add research] @id(web01)")
	writeNote(t, s, dir, "calendar.zortex", cal)
	expect(t, ts, "/broken", 200, `also on projects.zortex:16`, `is projects.zortex:16 but the link points at projects.zortex:15`)
}

func TestMirrorCarry(t *testing.T) {
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	s, dir, ts := mirrorServer(t, nil)
	url := ts.URL
	cal := filepath.Join(dir, "calendar.zortex")
	writeNote(t, s, dir, "calendar.zortex", []string{
		"@@Calendar", "",
		yesterday + ":",
		"09:00 [P/#1.4 - zortex]",
		"  - [ ] [./-Improve website] @id(web01)",
		"- [ ] Call the bank",
	})
	_, out := getJSON(t, ts, "/api/calendar")
	if out["carry"] != float64(2) {
		t.Fatalf("carry count: %v", out["carry"])
	}
	code, res := postJSON(t, url, "/api/calendar/carry", map[string]any{})
	if code != 200 || res["moved"] != float64(2) || res["added"] != float64(2) {
		t.Fatalf("carry: %d %v", code, res)
	}
	lines := readLines(t, cal)
	i := lineOf(t, lines, today()+":")
	got := strings.Join(lines[i-1:], "\n")
	// a new day gets a bold label
	if !strings.HasPrefix(got, edit.DateHeadingLine(today())+"\n- [P/#1.4 - zortex]\n  - [ ] [./-Improve website] @id(web01)\n- [ ] Call the bank @id(") {
		t.Fatalf("today:\n%s", got)
	}
	if l := lines[lineOf(t, lines, "[>] [./-Improve")-1]; l != "  - [>] [./-Improve website] @id(web01)" {
		t.Fatalf("old line: %q", l)
	}
	if _, out = getJSON(t, ts, "/api/calendar"); out["carry"] != float64(0) {
		t.Fatalf("nothing left: %v", out["carry"])
	}
}

func TestTrackBlockTasks(t *testing.T) {
	s, dir, _ := mirrorServer(t, nil)
	writeNote(t, s, dir, "calendar.zortex", []string{
		"@@Calendar", "",
		today() + ":",
		"00:00 [P/#1.4 - zortex]",
		"  - [x] [./-Highlight OKR ids] @id(okr01)",
		"  - [ ] [./-Improve website] @id(web01)",
		"  - [ ] [./-Change task sizes] @id(chg01)",
	})
	now := time.Now()
	if tg := s.calendarTarget(now); tg == nil || tg.ID != "web01" || tg.Rel != "calendar.zortex" {
		t.Fatalf("first open task of the block: %+v", tg)
	}
	lines := readLines(t, filepath.Join(dir, "calendar.zortex"))
	lines[lineOf(t, lines, "@id(web01)")-1] = "  - [x] [./-Improve website] @id(web01)"
	writeNote(t, s, dir, "calendar.zortex", lines)
	if tg := s.calendarTarget(now); tg == nil || tg.ID != "chg01" {
		t.Fatalf("then the next: %+v", tg)
	}
	// a reference under the block: the task it stands for
	writeNote(t, s, dir, "calendar.zortex", []string{
		"@@Calendar", "",
		today() + ":",
		"00:00 [P/#1.4 - zortex]",
		"  - [./-Change task sizes]",
	})
	if tg := s.calendarTarget(now); tg == nil || tg.Rel != "projects.zortex" || tg.Text != "Change task sizes" {
		t.Fatalf("reference: %+v", tg)
	}
}

// A checked calendar line without @id that links a task takes the task's
// @id when toggled (and gives the task one first when it has none), so the
// two become copies of one task.
func TestMirrorAdoptsLinkedID(t *testing.T) {
	s, dir, ts := mirrorServer(t, []string{
		"16:00 [P/#1.4 - zortex]",
		"  - [ ] [./-Improve website]",
		"  - [ ] [P/#1 Programming/#1.4 - zortex/-Add research-ready references]",
	})
	url := ts.URL
	cal, proj := filepath.Join(dir, "calendar.zortex"), filepath.Join(dir, "projects.zortex")

	// the task has an @id: the calendar line takes it, and both are done
	n, line := lineWith(t, cal, "[./-Improve website]")
	if code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "calendar.zortex", "lnum": n, "expect": line, "op": "toggle"}); code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	if _, l := lineWith(t, cal, "[./-Improve website]"); l != "  - [x] [./-Improve website] @id(web01) @done("+today()+")" {
		t.Fatalf("copy: %q", l)
	}
	if _, l := lineWith(t, proj, "Improve website"); !strings.HasPrefix(l, "- [x] Improve website") || !strings.Contains(l, "@id(web01)") {
		t.Fatalf("project task: %q", l)
	}

	// the task has no @id: it gets a new one, shared with the calendar line
	s.Refresh()
	n, line = lineWith(t, cal, "-Add research-ready references]")
	if code, out := postJSON(t, url, "/api/edit", map[string]any{"rel": "calendar.zortex", "lnum": n, "expect": line, "op": "toggle"}); code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	_, task := lineWith(t, proj, "Add research-ready references")
	_, copyLine := lineWith(t, cal, "-Add research-ready references]")
	id := edit.ID(task)
	if id == "" || edit.ID(copyLine) != id || !strings.HasPrefix(task, "- [x]") {
		t.Fatalf("task %q, copy %q", task, copyLine)
	}
	if issues := s.mirrorIssues(); len(issues) != 0 {
		t.Fatalf("ids don't line up: %+v", issues)
	}
}

// The only task of a calendar block, ticked without a size, gets the size
// nearest the block's length (edit.CalendarSize).
func TestCalendarTaskSizedByBlock(t *testing.T) {
	_, dir, ts := mirrorServer(t, []string{
		"16:00 Write the report",
		"  - [ ] Draft @id(rep01)",
		"17:00 Next",
	})
	cal := filepath.Join(dir, "calendar.zortex")
	n, line := lineWith(t, cal, "@id(rep01)")
	if code, out := postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "calendar.zortex", "lnum": n, "expect": line, "op": "toggle"}); code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	if _, l := lineWith(t, cal, "@id(rep01)"); l != "  - [x] Draft @id(rep01) @done("+today()+") @md" {
		t.Fatalf("sized: %q", l)
	}
}

// A calendar line holding only a project link, with nothing under it, lists
// the project's next open tasks; ticking one ticks the project task.
func TestProjectBlockTasks(t *testing.T) {
	_, dir, ts := mirrorServer(t, []string{
		"16:00 [P/#1.4 - zortex]",
		"17:00 Reflect on [P/#1.4 - zortex]",
	})
	var cal struct {
		Days map[string][]calEntry `json:"days"`
	}
	_, _, body := get(t, ts, "/api/calendar?from="+today()+"&to="+today())
	if err := json.Unmarshal([]byte(body), &cal); err != nil {
		t.Fatal(err)
	}
	var virtual []calEntry
	for _, e := range cal.Days[today()] {
		if e.Virtual {
			virtual = append(virtual, e)
		}
	}
	if len(virtual) != 3 || virtual[0].Text != "Add research-ready references" || virtual[0].Depth != 1 || virtual[0].Rel != "projects.zortex" {
		t.Fatalf("block tasks: %+v", virtual)
	}
	v := virtual[1]
	if code, out := postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": v.Rel, "lnum": v.Lnum, "expect": v.Src, "op": "toggle"}); code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	if _, l := lineWith(t, filepath.Join(dir, "projects.zortex"), "Improve website"); !strings.HasPrefix(l, "- [x] Improve website") {
		t.Fatalf("project task: %q", l)
	}
}
