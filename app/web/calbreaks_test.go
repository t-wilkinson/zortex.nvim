package web

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A break hands its block back: the day lists it again after the break
// (a resume row), and the time tracker follows the block once the break
// ends, not the break.
func TestBreaksResumeTheBlock(t *testing.T) {
	s, dir, ts := writableServer(t)
	_ = ts
	today := time.Now().Format("2006-01-02")
	cal := "@@Calendar\n\n" + today + ":\n" +
		"10:00 Work on [P/#1.4 - zortex/-Improve website]\n" +
		"12:00 Break @15m\n" +
		"14:00 Gym\n"
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte(cal), 0o644)
	s.Refresh()

	day := s.calendarDays(today, today)[today]
	var resume *calEntry
	for i := range day {
		if day[i].Resume {
			resume = &day[i]
		}
	}
	if resume == nil || resume.Time != "12:15" || resume.End != "14:00" || resume.Lnum != 4 || resume.Task {
		t.Fatalf("resume row: %+v (day %+v)", resume, day)
	}
	if len(day) != 4 || day[1].Lnum != 5 || !day[2].Resume || day[3].Lnum != 6 {
		t.Fatalf("the resume row goes right after the break: %+v", day)
	}

	y, m, d := time.Now().Date()
	at := func(h, min int) time.Time { return time.Date(y, m, d, h, min, 0, 0, time.Local) }
	if tg := s.calendarTarget(at(11, 0)); tg == nil || tg.Text != "Improve website" {
		t.Fatalf("11:00 is the block's task: %+v", tg)
	}
	if tg := s.calendarTarget(at(12, 5)); tg == nil || tg.Lnum != 5 {
		t.Fatalf("12:05 is the break: %+v", tg)
	}
	if tg := s.calendarTarget(at(12, 30)); tg == nil || tg.Text != "Improve website" {
		t.Fatalf("12:30 is the block's task again: %+v", tg)
	}
	if tg := s.calendarTarget(at(14, 30)); tg == nil || tg.Lnum != 6 {
		t.Fatalf("14:30 is the gym: %+v", tg)
	}
}

// A break inside a break's block: each resume comes once the rows nested
// under its break are done, the inner one first.
func TestNestedBreaksOrder(t *testing.T) {
	s, dir, _ := writableServer(t)
	today := time.Now().Format("2006-01-02")
	cal := "@@Calendar\n\n" + today + ":\n" +
		"10:00 Study\n" +
		"16:00 Write @2h\n" +
		"  17:00 Tea @10m\n" +
		"19:00 Dinner\n"
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte(cal), 0o644)
	s.Refresh()
	var got []string
	for _, e := range s.calendarDays(today, today)[today] {
		mark := ""
		if e.Resume {
			mark = "↩"
		}
		got = append(got, mark+e.Time+" "+e.Text)
	}
	want := []string{"10:00 Study", "16:00 Write", "17:00 Tea", "↩17:10 Write", "↩18:00 Study", "19:00 Dinner"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}
