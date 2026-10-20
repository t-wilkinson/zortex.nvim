package web

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// The calendar's # Repeating rules on the web: shown on the days they land
// on, ticked into today (POST /api/calendar/repeat), the copy standing for
// the occurrence after that; a new day starts from # Templates.
func TestRepeatingOnTheWeb(t *testing.T) {
	s, dir, ts := writableServer(t)
	now := time.Now()
	today := now.Format("2006-01-02")
	yesterday := now.AddDate(0, 0, -1).Format("2006-01-02")
	cal := strings.Join([]string{
		"@@Calendar", "@@C", "",
		"# Templates", "Daily:", "Outcomes:", "",
		"# Repeating", "## Birthdays",
		"- Sam's birthday @repeat(" + today[5:] + ") @born(1990)",
		"## Routines",
		"- [ ] Stretch @repeat(daily)",
		"- Not a rule",
		"", "# Days", "",
		"2020-01-01:", "- long ago",
	}, "\n") + "\n"
	path := filepath.Join(dir, "calendar.zortex")
	if err := os.WriteFile(path, []byte(cal), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	type entry struct {
		Lnum   int    `json:"lnum"`
		Text   string `json:"text"`
		HTML   string `json:"html"`
		Task   bool   `json:"task"`
		Done   bool   `json:"done"`
		Repeat bool   `json:"repeat"`
		Copy   int    `json:"copy"`
		Src    string `json:"src"`
		Date   string `json:"date"`
	}
	day := func(date string) []entry {
		_, _, body := get(t, ts, "/api/calendar?from="+yesterday+"&to="+today)
		var out struct {
			Days map[string][]entry `json:"days"`
		}
		json.Unmarshal([]byte(body), &out)
		return out.Days[date]
	}
	got := day(today)
	age := now.Year() - 1990
	if len(got) != 2 || !got[0].Repeat || got[0].Text != "Sam's birthday ("+itoa(age)+")" || !strings.HasSuffix(got[0].HTML, "("+itoa(age)+")") ||
		got[1].Text != "Stretch" || !got[1].Task || got[1].Done {
		t.Fatalf("today: %+v", got)
	}
	// tick yesterday's stretch: a copy in today, @for yesterday, and today made from its template
	stretch := day(yesterday)[0]
	code, out := postJSON(t, ts.URL, "/api/calendar/repeat", map[string]any{"lnum": stretch.Lnum, "expect": stretch.Src, "date": yesterday})
	if code != 200 {
		t.Fatalf("repeat: %d %v", code, out)
	}
	lines := readLines(t, path)
	n := lineOf(t, lines, "**"+today+":**")
	if lines[n] != "Outcomes:" || !regexp.MustCompile(`^- \[x\] Stretch @id\(\w{5}\) @done\(`+today+`\) @for\(`+yesterday+`\)$`).MatchString(lines[n+1]) {
		t.Fatalf("today's block: %q", lines[n-1:])
	}
	s.Refresh()
	y := day(yesterday)[0]
	if !y.Done || y.Copy != n+2 || y.Lnum != n+2 {
		t.Errorf("yesterday's occurrence stands for its copy: %+v", y)
	}
	// ticking today's: its copy shows instead of it
	var st entry
	for _, e := range day(today) {
		if e.Repeat && e.Text == "Stretch" {
			st = e
		}
	}
	if st.Copy != 0 {
		t.Fatalf("a copy @for yesterday doesn't stand for today: %+v", st)
	}
	if code, out := postJSON(t, ts.URL, "/api/calendar/repeat", map[string]any{"lnum": st.Lnum, "expect": st.Src, "date": today}); code != 200 {
		t.Fatalf("repeat today: %d %v", code, out)
	}
	s.Refresh()
	repeats := 0
	for _, e := range day(today) {
		if e.Repeat && e.Text == "Stretch" {
			repeats++
		}
	}
	if repeats != 0 {
		t.Error("today's occurrence shows its copy instead")
	}
	// not a rule, or a stale line: refused
	if code, _ := postJSON(t, ts.URL, "/api/calendar/repeat", map[string]any{"lnum": lineOf(t, readLines(t, path), "Sam's"), "expect": "- Sam's birthday", "date": today}); code != 409 {
		t.Errorf("stale line: %d", code)
	}
	l := lineOf(t, readLines(t, path), "Sam's")
	if code, _ := postJSON(t, ts.URL, "/api/calendar/repeat", map[string]any{"lnum": l, "expect": readLines(t, path)[l-1], "date": today}); code != 422 {
		t.Errorf("a birthday isn't a task: %d", code)
	}
}
