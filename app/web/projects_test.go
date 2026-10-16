package web

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func projectByName(all []*webProject, name string) *webProject {
	for _, p := range all {
		if p.Name == name {
			return p
		}
	}
	return nil
}

func TestProjectsTree(t *testing.T) {
	s, _, _ := newTestServer(t, "")
	all := s.allProjects()
	z := projectByName(all, "1.4 - zortex")
	if z == nil || z.Link != "[P/#1 Programming/#1.4 - zortex]" || z.Parent.Name != "1 Programming" {
		t.Fatalf("zortex: %+v", z)
	}
	// its own tasks stop at its sub-project; labels and notes are content
	var texts []string
	for _, task := range z.Tasks {
		texts = append(texts, strings.TrimSpace(string(task.HTML)))
	}
	if len(z.Tasks) != 5 || z.Children[0].Name != "1.4.1 - zortex search" || len(z.Children[0].Tasks) != 1 {
		t.Fatalf("tasks %q children %v", texts, z.Children)
	}
	// hours: md 1 + xl 3 + unsized 1 (open), xs 0.25 + unsized 1 (done); its sub-project's sm 0.5
	r := z.rollup()
	if r.Total != 6 || r.DoneN != 2 || r.Hours != 6.75 || r.DoneHours != 1.25 {
		t.Fatalf("rollup %+v", r)
	}
	if z.Size != "lg" || len(z.Areas) != 1 || z.Areas[0] != "4.1" {
		t.Fatalf("attributes %+v", z)
	}
	// an @P note is a root project linked by its name
	flip := projectByName(all, "Flipping")
	if flip == nil || !flip.Root || flip.Link != "[P/Flipping]" {
		t.Fatalf("flipping: %+v", flip)
	}
	if len(flip.Children) == 0 || !strings.HasPrefix(flip.Children[0].Link, "[P/Flipping/#") {
		t.Fatalf("flipping children: %+v", flip.Children)
	}
}

func TestObjectiveWindow(t *testing.T) {
	cases := []struct{ span, period, from, to string }{
		{"3M", "Q4", "2026-10-01", "2026-12-31"},
		{"6M", "H2", "2026-07-01", "2026-12-31"},
		{"1M", "03", "2026-03-01", "2026-03-31"},
		{"1M", "M3", "2026-03-01", "2026-03-31"},
		{"1Y", "Y", "2026-01-01", "2026-12-31"},
		{"4M", "08", "2026-08-01", "2026-11-30"},
	}
	for _, c := range cases {
		a, b := objectiveWindow(c.span, 2026, c.period)
		if a.Format("2006-01-02") != c.from || b.Format("2006-01-02") != c.to {
			t.Errorf("%s-%s: %s..%s", c.span, c.period, a.Format("2006-01-02"), b.Format("2006-01-02"))
		}
	}
	a, b := objectiveWindow("3M", 2026, "Q4")
	if e := elapsed(a, b, time.Date(2026, 11, 15, 9, 0, 0, 0, time.Local)); e < 0.49 || e > 0.51 {
		t.Errorf("elapsed %v", e)
	}
}

func TestKeyResultsAndFocus(t *testing.T) {
	s, dir, _ := newTestServer(t, "")
	week := isoWeek(time.Now())
	os.WriteFile(filepath.Join(dir, "reviews.zortex"), []byte("@@Reviews\n\n# "+week+"\nFocus:\n- [P/#1.4 - esp32]\nWins:\n- [P/#Habits]\n\n# 2020-W01\nFocus:\n- [P/#Habits]\n"), 0o644)
	s.Refresh()
	all := s.allProjects()
	krs := s.keyResults(all, time.Now())
	byText := map[string]webKR{}
	for _, kr := range krs {
		byText[kr.ID+" "+kr.Text] = kr
	}
	habits := byText["KR2 Make list of habits and routines"]
	if len(habits.Projects) != 1 || habits.Projects[0].Name != "Habits" || habits.Percent() != 50 {
		t.Fatalf("habits KR: %+v (%v)", habits, byText)
	}
	if done := byText["KR1 Projects API"]; !done.Done || done.Progress != 1 {
		t.Fatalf("checked KR: %+v", done)
	}
	// a KR linking a sub-project by a prefix resolves to it
	if search := byText["KR2 Search works"]; len(search.Projects) != 1 || search.Projects[0].Name != "1.4.1 - zortex search" {
		t.Fatalf("search KR: %+v", search)
	}
	// only the Focus label's links; the newest week first
	w, focus, earlier := s.focus(all, time.Now())
	if w != week || earlier || len(focus) != 1 || focus[0].Name != "1.4 - esp32" {
		t.Fatalf("focus %s %v %v", w, focus, earlier)
	}
}

func TestProjectPages(t *testing.T) {
	s, dir, ts := writableServer(t)
	today := time.Now()
	day := func(n int) string { return today.AddDate(0, 0, n).Format("2006-01-02") }
	proj := filepath.Join(dir, "projects.zortex")
	raw, _ := os.ReadFile(proj)
	os.WriteFile(proj, []byte(strings.Replace(string(raw), "- [ ] Compile code @size(sm)", "- [ ] Compile code @size(sm) @id(esp01)", 1)), 0o644)
	copyLine := "- [>] [P/#1 Programming/#1.4 - esp32/-Compile code] @id(esp01)"
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte("@@Calendar\n\n"+
		day(-2)+":\n"+copyLine+"\n\n"+
		day(-1)+":\n"+copyLine+"\n10:00 Solder headers [P/#1.4 - esp32]\n\n"+
		day(0)+":\n- [ ] [P/#1 Programming/#1.4 - esp32/-Compile code] @id(esp01)\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "reviews.zortex"), []byte("@@Reviews\n\n# "+isoWeek(today)+"\nFocus:\n- [P/#1.4 - esp32]\n"), 0o644)
	s.Refresh()

	// the list: focus first, then the rest with open work
	page := expect(t, ts, "/projects", 200, "Focus · "+isoWeek(today), "1.4 - esp32", "put off ×2", "1.4 - zortex", `href="/project?rel=projects.zortex&amp;lnum=`)
	if strings.Index(page, "1.4 - esp32") > strings.Index(page, "With open tasks") {
		t.Fatalf("focus first:\n%s", page)
	}
	// the home page shows the week's focus too
	expect(t, ts, "/", 200, `id="focus-title"`, "1.4 - esp32")

	all := s.allProjects()
	esp := projectByName(all, "1.4 - esp32")
	url := "/project?rel=projects.zortex&lnum=" + strconv.Itoa(esp.Lnum)
	expect(t, ts, url, 200, "<h1>1.4 - esp32</h1>", "focus · "+isoWeek(today), "put off ×2", "On the calendar", day(-1), "Solder headers", "carried on", `class="pcheck"`)
	expect(t, ts, "/project?rel=projects.zortex&lnum=2", 404)

	// the log: made under its tasks, newest first
	heading := esp.doc.Lines[esp.Lnum-1]
	if code, out := postJSON(t, ts.URL, "/api/project/log", map[string]any{"rel": "projects.zortex", "lnum": esp.Lnum, "expect": heading, "text": "Flashed the bootloader"}); code != 200 {
		t.Fatalf("log: %d %v", code, out)
	}
	postJSON(t, ts.URL, "/api/project/log", map[string]any{"rel": "projects.zortex", "lnum": esp.Lnum, "expect": heading, "text": "  I2C   needs pull-ups "})
	lines := readLines(t, proj)
	at := esp.Lnum
	want := []string{heading, "- [ ] Compile code @size(sm) @id(esp01)", "", "Log:", "- " + day(0) + ": I2C needs pull-ups", "- " + day(0) + ": Flashed the bootloader", ""}
	for i, w := range want {
		if lines[at-1+i] != w {
			t.Fatalf("line %d: %q, want %q\n%s", at+i, lines[at-1+i], w, strings.Join(lines, "\n"))
		}
	}
	if !strings.HasPrefix(lines[at-1+len(want)], "## 1.4 - zortex") {
		t.Fatalf("next heading kept: %q", lines[at-1+len(want)])
	}
	expect(t, ts, url, 200, "I2C needs pull-ups")
	// a stale page is refused
	if code, _ := postJSON(t, ts.URL, "/api/project/log", map[string]any{"rel": "projects.zortex", "lnum": esp.Lnum, "expect": "## old", "text": "x"}); code != 409 {
		t.Fatalf("stale: %d", code)
	}
}
