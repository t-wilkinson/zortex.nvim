package web

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The reviews note, written the way Neovim's services/review writes it.
func TestReviewsNoteEntries(t *testing.T) {
	lines := newReviewsNote()
	lines, at := ensureWeek(lines, "2026-W43")
	if lines[at-1] != "# 2026-W43" || lines[at] != "Focus:" {
		t.Fatalf("week from the note's template:\n%s", strings.Join(lines, "\n"))
	}
	// newest first, before the templates when they come after every week
	lines, _ = ensureWeek(lines, "2026-W44")
	weeks, order := reviewEntries(lines)
	if strings.Join(order, ",") != "2026-W44,2026-W43" || weeks["2026-W44"].Lnum >= weeks["2026-W43"].Lnum {
		t.Fatalf("order %v\n%s", order, strings.Join(lines, "\n"))
	}
	lines, day := ensureDay(lines, "2026-10-21", "2026-W43")
	if lines[day-1] != "## 2026-10-21" || lines[day] != "Done:" {
		t.Fatalf("day:\n%s", strings.Join(lines, "\n"))
	}
	from, to, ok := entryRange(lines, "2026-W43", "2026-10-21")
	if !ok {
		t.Fatal("no day entry")
	}
	if got := strings.Join(entryLabels(lines, from, to), ","); got != "Done,Blocked,First thing tomorrow" {
		t.Fatalf("labels %q", got)
	}
	lines, at = addUnderLabel(lines, from, to, "Done", "Lapped the valves")
	lines, _ = addUnderLabel(lines, from, to+1, "Done", "Torqued the head")
	if lines[at-1] != "- Lapped the valves" || lines[at-2] != "Done:" || lines[at] != "- Torqued the head" || lines[at+1] != "Blocked:" {
		t.Fatalf("under Done:\n%s", strings.Join(lines, "\n"))
	}
	// a label the entry doesn't have is added
	from, to, _ = entryRange(lines, "2026-W43", "")
	lines, at = addUnderLabel(lines, from, to, "Energy", "low midweek")
	if lines[at-2] != "Energy:" || lines[at-1] != "- low midweek" {
		t.Fatalf("new label:\n%s", strings.Join(lines, "\n"))
	}
	// the Focus label and its lines
	lines, at = addUnderLabel(lines, from, to+2, "Focus", "[P/#1.4]")
	weeks, _ = reviewEntries(lines)
	if e := weeks["2026-W43"]; e.FocusLnum == 0 || e.FocusFrom != at || e.FocusTo != at {
		t.Fatalf("focus %+v at %d\n%s", e, at, strings.Join(lines, "\n"))
	}
}

func TestReviewWindows(t *testing.T) {
	st := reviewState{LastDay: "2026-10-20", From: "2026-10-18"}
	if got := dayWindow(st, "2026-10-22"); got != "2026-10-21" {
		t.Errorf("after the last review: %s", got)
	}
	if got := dayWindow(st, "2026-10-20"); got != "2026-10-18" {
		t.Errorf("the same day again: %s", got)
	}
	if got := dayWindow(reviewState{}, "2026-10-22"); got != "2026-10-22" {
		t.Errorf("never reviewed: %s", got)
	}
	if got := dayWindow(reviewState{LastDay: "2026-09-01"}, "2026-10-22"); got != "2026-10-16" {
		t.Errorf("at most a week: %s", got)
	}
	if got := areaWindow(st, "2026-10-22", "2026-10-21"); got != "2026-10-20" {
		t.Errorf("work finished after the last review: %s", got)
	}
	for in, want := range map[string]string{"2026-10-21": "2026-10-21", "+3": "", "tomorrow": "", "nope": "x"} {
		got, ok := parseDay(in, mustDate("2026-10-20"))
		switch want {
		case "":
			if !ok || got <= "2026-10-20" {
				t.Errorf("%q: %q %v", in, got, ok)
			}
		case "x":
			if ok {
				t.Errorf("%q: accepted %q", in, got)
			}
		default:
			if got != want {
				t.Errorf("%q: %q", in, got)
			}
		}
	}
	if got := bracketLink("[P/#1 Programming/#1.4 - zortex]"); got != "[P/#1 Programming/#1.4 - zortex]" {
		t.Error(got)
	}
	if withArea("- [x] Done @area(9) @done(2026-10-06)", "4.1") != "- [x] Done @done(2026-10-06) @a(4.1)" {
		t.Error(withArea("- [x] Done @area(9) @done(2026-10-06)", "4.1"))
	}
}

// The daily review on the web, and its fixes.
func TestDailyReviewOnTheWeb(t *testing.T) {
	s, dir, ts := writableServer(t)
	write := func(rel, content string) {
		if err := os.WriteFile(filepath.Join(dir, rel), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	areas := readLines(t, filepath.Join(dir, "areas.zortex"))
	areas = append(areas[:3], append([]string{"# 0 General", "## 0.1 Unassigned"}, areas[3:]...)...)
	write("areas.zortex", strings.Join(areas, "\n")+"\n")
	write("inbox.zortex", "@@Inbox\n\n- Call the plumber @project(1.4 - esp32)\n    - about the leak\n- Read [./doc-1]\n")
	write("calendar.zortex", "@@Calendar\n\n**2026-10-08:**\n14:00 [ ] Write the notes\n- [x] Water the plants @done(2026-10-08)\n- [x] Fix the gate @a(1.1) @done(2026-10-08)\n")
	s.Refresh()

	page := expect(t, ts, "/review?day=2026-10-08", 200, `<h1>2026-10-08</h1>`, `Done without an area`, `Water the plants`, `Habits`,
		`Call the plumber`, `Move to project`, `→ Tomorrow`, `data-act="finish"`, `Give it an area`,
		`data-line="14:00 [ ] Write the notes"`) // the line as written, for the edit (not escaped as a URL)
	section := page[strings.Index(page, `id="unassigned"`):]
	section = section[:strings.Index(section[10:], `<h2`)+10]
	if strings.Contains(section, `Fix the gate`) || !strings.Contains(section, `Water the plants`) {
		t.Errorf("work with an area isn't asked about:\n%s", section)
	}
	// the @project line has its project picked
	if !strings.Contains(page, `selected>1 Programming › 1.4 - esp32`) {
		t.Error("Move preselects the @project's project")
	}

	// move: the line and the line under it, without @project, to the project
	inbox := readLines(t, filepath.Join(dir, "inbox.zortex"))
	all := s.allProjects()
	var esp *webProject
	for _, p := range all {
		if p.Name == "1.4 - esp32" {
			esp = p
		}
	}
	code, out := postJSON(t, ts.URL, "/api/review/move", map[string]any{"rel": "inbox.zortex", "lnum": 3, "expect": inbox[2], "to": "projects.zortex:" + itoa(esp.Lnum)})
	if code != 200 {
		t.Fatalf("move: %d %v", code, out)
	}
	proj := strings.Join(readLines(t, filepath.Join(dir, "projects.zortex")), "\n")
	if !strings.Contains(proj, "- [ ] Compile code @size(sm)\n- Call the plumber\n    - about the leak") {
		t.Fatalf("moved:\n%s", proj)
	}
	if got := strings.Join(readLines(t, filepath.Join(dir, "inbox.zortex")), "\n"); strings.Contains(got, "plumber") || strings.Contains(got, "leak") {
		t.Fatalf("still in the inbox:\n%s", got)
	}

	// tomorrow: [>] here, a copy on the next day at the same time
	cal := readLines(t, filepath.Join(dir, "calendar.zortex"))
	if code, out := postJSON(t, ts.URL, "/api/review/tomorrow", map[string]any{"lnum": 4, "expect": cal[3]}); code != 200 || out["date"] != "2026-10-09" {
		t.Fatalf("tomorrow: %d %v", code, out)
	}
	cal = readLines(t, filepath.Join(dir, "calendar.zortex"))
	joined := strings.Join(cal, "\n")
	if !strings.HasPrefix(cal[3], "14:00 [>] Write the notes @id(") || !strings.Contains(joined, "**2026-10-09:**\n14:00 [ ] Write the notes @id(") {
		t.Fatalf("calendar:\n%s", joined)
	}
	// a stale line is refused
	if code, _ := postJSON(t, ts.URL, "/api/review/tomorrow", map[string]any{"lnum": 4, "expect": "14:00 [ ] Write the notes"}); code != 409 {
		t.Fatalf("stale: %d", code)
	}

	// area: on a project's heading
	s.Refresh()
	var habits *webProject
	for _, p := range s.allProjects() {
		if p.Name == "Habits" {
			habits = p
		}
	}
	plines := readLines(t, filepath.Join(dir, "projects.zortex"))
	if code, out := postJSON(t, ts.URL, "/api/review/area", map[string]any{"rel": "projects.zortex", "lnum": habits.Lnum, "expect": plines[habits.Lnum-1], "area": "4.1"}); code != 200 {
		t.Fatalf("area: %d %v", code, out)
	}
	if got := readLines(t, filepath.Join(dir, "projects.zortex"))[habits.Lnum-1]; got != "## Habits @a(4.1)" {
		t.Fatalf("heading: %q", got)
	}
	if code, _ := postJSON(t, ts.URL, "/api/review/area", map[string]any{"rel": "projects.zortex", "lnum": habits.Lnum, "expect": "## Habits @a(4.1)", "area": "9.9"}); code != 422 {
		t.Fatalf("an area that doesn't exist: %d", code)
	}

	// due
	plines = readLines(t, filepath.Join(dir, "projects.zortex"))
	for i, l := range plines {
		if strings.HasPrefix(l, "- [ ] Compile code") {
			if code, out := postJSON(t, ts.URL, "/api/review/due", map[string]any{"rel": "projects.zortex", "lnum": i + 1, "expect": l, "due": "2026-11-01"}); code != 200 {
				t.Fatalf("due: %d %v", code, out)
			}
			if got := readLines(t, filepath.Join(dir, "projects.zortex"))[i]; got != "- [ ] Compile code @size(sm) @due(2026-11-01)" {
				t.Fatalf("due: %q", got)
			}
		}
	}

	// a line in the day's entry, the reviews note made from its template
	if code, out := postJSON(t, ts.URL, "/api/review/note", map[string]any{"date": "2026-10-08", "label": "Done", "text": "Lapped the valves"}); code != 200 {
		t.Fatalf("note: %d %v", code, out)
	}
	rv := strings.Join(readLines(t, filepath.Join(dir, "reviews.zortex")), "\n")
	if !strings.Contains(rv, "# 2026-W41\nFocus:") || !strings.Contains(rv, "## 2026-10-08\nDone:\n- Lapped the valves\nBlocked:") {
		t.Fatalf("reviews:\n%s", rv)
	}

	// focus: in, then out
	s.Refresh()
	for _, want := range []bool{true, false} {
		code, out := postJSON(t, ts.URL, "/api/review/focus", map[string]any{"week": "2026-W41", "rel": "projects.zortex", "lnum": esp.Lnum})
		if code != 200 || out["added"] != want {
			t.Fatalf("focus: %d %v", code, out)
		}
		rv = strings.Join(readLines(t, filepath.Join(dir, "reviews.zortex")), "\n")
		if strings.Contains(rv, "- [P/#1 Programming/#1.4 - esp32]") != want {
			t.Fatalf("focus %v:\n%s", want, rv)
		}
		s.Refresh()
	}

	// finish: @a(0.1) on what is still without an area, the day reviewed
	code, out = postJSON(t, ts.URL, "/api/review/finish", map[string]any{"date": "2026-10-08"})
	if code != 200 || out["stamped"].(float64) < 1 {
		t.Fatalf("finish: %d %v", code, out)
	}
	if got := strings.Join(readLines(t, filepath.Join(dir, "calendar.zortex")), "\n"); !strings.Contains(got, "- [x] Water the plants @done(2026-10-08) @a(0.1)") || strings.Contains(got, "Fix the gate @a(1.1) @done(2026-10-08) @a(0.1)") {
		t.Fatalf("stamped:\n%s", got)
	}
	var st reviewState
	raw, _ := os.ReadFile(filepath.Join(dir, ".z", "review_state.json"))
	if json.Unmarshal(raw, &st) != nil || st.LastDay != "2026-10-08" || st.Version != 1 {
		t.Fatalf("review state: %s", raw)
	}
	s.Refresh()
	expect(t, ts, "/review?day=2026-10-08", 200, `reviewed`, `has an area`)
}

// Not writable: the review reads, and its fixes are refused.
func TestReviewFixesNeedWritable(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	page := expect(t, ts, "/review?day=today", 200, `Daily`)
	if strings.Contains(page, `data-act="finish"`) {
		t.Error("no fixes without -writable")
	}
	if code, _ := postJSON(t, ts.URL, "/api/review/finish", map[string]any{}); code != 403 {
		t.Errorf("finish read-only: %d", code)
	}
}

func mustDate(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return t
}
