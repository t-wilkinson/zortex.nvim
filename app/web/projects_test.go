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

// Objectives are "## SPAN Title" and deeper; a top-level heading (the
// season's, "# 3M-2026-Q4 Season 1 Aspen") only groups them.
func TestObjectiveHeadings(t *testing.T) {
	_, s := newSlidesServerWith(t, map[string]string{"okr.zortex": "@@OKR\n\n" +
		"# 3M-2026-Q4 Season 10 Juniper\n## 3M-2026-Q4 Learn piano @a(4.1)\n- KR1: [x] Scales\n### Notes\n" +
		"## 1M-2026-11 Ship it\n- KR1: [ ] Done\n\n" +
		"# Current\n## 3M-2026-Q1 Eat well\n- KR1: [ ] Cook\n"})
	objs := s.objectives(nil, time.Date(2026, 11, 1, 9, 0, 0, 0, time.Local))
	var got []string
	for _, o := range objs {
		got = append(got, o.Span+" "+o.Title+" "+o.Start.Format("01-02")+".."+o.End.Format("01-02")+" "+strconv.Itoa(len(o.KRs)))
	}
	want := []string{"3M-2026-Q4 Learn piano 10-01..12-31 1", "1M-2026-11 Ship it 11-01..11-30 1", "3M-2026-Q1 Eat well 01-01..03-31 1"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("objectives %q, want %q", got, want)
	}
	if len(objs[0].Areas) != 1 || objs[0].Progress != 1 {
		t.Errorf("objective: %+v", objs[0])
	}
}

// A key result on /okr: its text without "KR1:" (the id is its pill) and
// without the links to the projects listed under it; the project rows
// don't repeat the id.
func TestOKRKeyResultText(t *testing.T) {
	ts, _ := newSlidesServerWith(t, map[string]string{
		"projects.zortex": "@@Projects\n@@P\n\n# Bake bread\n- [ ] Feed the starter\n",
		"okr.zortex": "@@OKR\n\n# 3M-2026-Q4 Season 1 Aspen\n## 3M-2026-Q4 Eat well\n" +
			"- KR1: Bake every weekend [P/#Bake bread] with [a recipe](https://example.com)\n" +
			"- KR2: [ ] Cook twice a week\n",
	})
	page := expect(t, ts, "/okr", 200, `3M-2026-Q4`, `Eat well`, `class="prow-name"`, `Bake every weekend`, `href="https://example.com"`, `Cook twice a week`)
	krs := page[strings.Index(page, `class="okr-krs"`):]
	if strings.Contains(krs, "KR1:") || strings.Contains(krs, "KR2:") {
		t.Error("the key is not repeated in the text")
	}
	text := krs[strings.Index(krs, `class="okr-kr-text"`):]
	text = text[:strings.Index(text, `</span>`)]
	if strings.Contains(text, "Bake bread") {
		t.Errorf("the project link is shown as its row, not in the text: %s", text)
	}
	if strings.Count(krs, `>KR1<`) != 1 {
		t.Error("the project row doesn't repeat the key result's id")
	}
}

// The current quarter's period on /okr shows the season's tier: Neovim's
// when it published the season of that span, else estimated here; a key
// result nothing can move is flagged.
func TestOKRSeasonTierAndStuckKRs(t *testing.T) {
	span := quarterSpan(time.Now())
	ts, s := newSlidesServerWith(t, map[string]string{
		"okr.zortex": "@@OKR\n\n# " + span + " Season 3 Cedar\n## " + span + " Run\n- KR1: [x] Run a 10k\n## " + span + " Read\n- KR1: Read more\n- KR2: [ ] Ten books\n" +
			"## 1Y-2026-Y Longer\n- KR1: [ ] Something\n",
	})
	// estimated: Run done, Read at 0 -> 50%, Silver; only the quarter has a tier
	page := expect(t, ts, "/okr", 200, span, `Silver · 50%`, `Gold at 70%`, `estimated here`)
	if strings.Count(page, `estimated here`) != 1 {
		t.Error("only the current quarter's period has a tier")
	}
	if strings.Count(page, `>stuck<`) != 1 || !strings.Contains(page, `Nothing can move it`) {
		t.Error("only the KR with no project and no checkbox is stuck")
	}
	// Neovim's figure wins when it published the season of that span
	os.MkdirAll(filepath.Join(s.cfg.Root, ".z"), 0o755)
	os.WriteFile(filepath.Join(s.cfg.Root, ".z", "xp_summary.json"), []byte(`{"version":2,"generated":"`+time.Now().UTC().Format(time.RFC3339)+
		`","season":{"name":"Season 3 Cedar","span":"`+span+`","progress":0.72,"tier":"Gold","next_tier":"Platinum","next_at":0.85}}`), 0o644)
	expect(t, ts, "/okr", 200, span+` Season 3 Cedar ·`, `Gold · 72%`, `Platinum at 85%`, `from Neovim`)
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

// The domain views: objectives against their window, the weekly review.
func TestObjectivesAndReviewPages(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	okr := expect(t, ts, "/okr", 200, `<h1>Objectives</h1>`, `Ship zortex projects`, `KR1`, `aria-current="page">Objectives`)
	if !strings.Contains(okr, `class="prow-name"`) {
		t.Error("key results list the projects they link")
	}
	expect(t, ts, "/review", 200, `aria-current="page">Weekly`, `class="tile"`, `Inbox`)
	week := expect(t, ts, "/review?week=2026-W02", 200, `<h1>2026-W02</h1>`, `Jan 5 – Jan 11, 2026`, `2026-W01`, `2026-W03`)
	_ = week
	expect(t, ts, "/review?week=nonsense", 200, `aria-current="page">Weekly`)
	expect(t, ts, "/review?day=today", 200, `aria-current="page">Daily`, `Completed`, `The day in reviews.zortex`)
	expect(t, ts, "/projects", 200, `href="/review"`)
}

// The review page shows what the week's entry says besides its focus.
func TestReviewPageShowsTheWeeksNotes(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	note := "@@Reviews\n\n# 2026-W03\nOnly W03\n\n" +
		"# 2026-W02\nEnergy: low midweek\nFocus:\n- [P/#1.4 - zortex]\nWins:\n- Shipped the parser\nLessons:\n" +
		"\n## 2026-01-06\nDone:\n- A day line\n"
	if err := os.WriteFile(filepath.Join(dir, "reviews.zortex"), []byte(note), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	page := expect(t, ts, "/review?week=2026-W02", 200, `class="body rv-notes"`, `Shipped the parser`, `Energy`, `low midweek`, `In reviews.zortex`)
	notes := page[strings.Index(page, `rv-notes`):]
	notes = notes[:strings.Index(notes, `In reviews.zortex`)]
	for _, not := range []string{`Focus`, `Lessons`, `A day line`, `Only W03`} {
		if strings.Contains(notes, not) {
			t.Errorf("the week's notes show %q", not)
		}
	}
	if !strings.Contains(notes, `Wins`) {
		t.Error("a label with lines under it is shown")
	}
	if strings.Contains(expect(t, ts, "/review?week=2026-W05", 200), `rv-notes`) {
		t.Error("a week with no entry shows no notes")
	}
}

// Organizational headings (no task of their own, no project attribute)
// aren't projects; they still name the projects under them. Linked, with
// projects under them, they are projects again (lua: test_projects_org).
func TestOrganizationalHeadings(t *testing.T) {
	note := "@@Org test\n@P\n\n" +
		"# Car @cars\nNotes about the car, no tasks.\n## Rebuild engine\n- [ ] Lap the valves\n## Fix brakes\n- [x] Order pads\n" +
		"# Someday ideas @ideas\n## Empty idea\n" +
		"# Learn piano @lg\n" +
		"# Parked @someday\n" +
		"# Home\n- [ ] Fix the gate\n## Garden\n### Beds\n- [ ] Dig\n"
	build := func(extra string) []*webProject {
		files := map[string]string{"org-test.zortex": note}
		if extra != "" {
			files["org-links.zortex"] = extra
		}
		_, s := newSlidesServerWith(t, files)
		var out []*webProject
		for _, p := range s.allProjects() {
			if p.Rel == "org-test.zortex" {
				out = append(out, p)
			}
		}
		return out
	}
	names := func(list []*webProject) []string {
		var out []string
		for _, p := range list {
			out = append(out, p.Link)
		}
		return out
	}
	got := names(build(""))
	want := []string{
		"[P/Org test]",
		"[P/Org test/#Car/#Rebuild engine]",
		"[P/Org test/#Car/#Fix brakes]",
		"[P/Org test/#Learn piano]",
		"[P/Org test/#Parked]",
		"[P/Org test/#Home]",
		"[P/Org test/#Home/#Garden/#Beds]",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("projects:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	for _, p := range build("") {
		switch p.Name {
		case "Home":
			if p.OwnEnd != 15 || len(p.Tasks) != 1 {
				t.Errorf("Home's own lines end at %d with %d tasks", p.OwnEnd, len(p.Tasks))
			}
		case "Beds":
			if p.Parent == nil || p.Parent.Name != "Home" {
				t.Error("Beds' project is Home")
			}
		case "Org test":
			if p.OwnEnd != 3 {
				t.Errorf("the root's own lines end at %d, not before # Car", p.OwnEnd)
			}
		}
	}
	// a link's target: the project it is in, none for an organizational
	// heading with nothing under it
	ts, srv := newSlidesServerWith(t, map[string]string{"org-test.zortex": note})
	_ = ts
	all := srv.allProjects()
	doc := srv.ix.Doc("org-test.zortex")
	if got := projectsFor(all, "org-test.zortex", 11, doc); len(got) != 0 {
		t.Errorf("Empty idea stands for %v", names(got))
	}
	if got := names(projectsFor(all, "org-test.zortex", 7, doc)); len(got) != 1 || got[0] != "[P/Org test/#Car/#Rebuild engine]" {
		t.Errorf("a task line stands for %v", got)
	}
	// linked from another note, with projects under it: a project again
	linked := names(build("@@Org links\n\n- [P/Org test/#Car] needs work\n- [P/Org test/#Someday ideas/#Empty idea]\n"))
	if !strings.Contains(strings.Join(linked, "\n"), "[P/Org test/#Car]\n") {
		t.Errorf("a linked Car with projects under it isn't a project: %v", linked)
	}
	if strings.Contains(strings.Join(linked, "\n"), "Empty idea") {
		t.Error("a linked heading with nothing under it became a project")
	}
}
