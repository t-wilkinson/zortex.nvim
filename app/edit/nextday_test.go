package edit

import (
	"strings"
	"testing"
)

func TestToNextDay(t *testing.T) {
	ids := 0
	newID := func() string { ids++; return "new0" + string(rune('0'+ids)) }
	lines := []string{
		"@@Calendar",
		"",
		"**2026-10-11:**",
		"14:00 [ ] Write the notes",
		"09:00 [P/#1 Programming/#1.4 - zortex]",
		"  - [ ] [./-Improve website] @id(imp01)",
		"- [x] Done already",
		"",
		"**2026-10-12:**",
		"09:00 Standup",
		"16:00 Gym",
	}
	// a timed task: as written, before the next day's first later timed line
	out, day, at, err := ToNextDay(lines, 4, newID)
	if err != nil {
		t.Fatal(err)
	}
	if day != "2026-10-12" || out[3] != "14:00 [>] Write the notes @id(new01)" {
		t.Fatalf("marked: %q %q", day, out[3])
	}
	if at != 11 || out[at-1] != "14:00 [ ] Write the notes @id(new01)" || out[at] != "16:00 Gym" {
		t.Fatalf("copy at %d:\n%s", at, strings.Join(out, "\n"))
	}
	// a task in a block: its link made absolute, at the end of the day
	out, _, at, err = ToNextDay(out, 6, newID)
	if err != nil {
		t.Fatal(err)
	}
	if out[5] != "  - [>] [./-Improve website] @id(imp01)" {
		t.Fatalf("marked: %q", out[5])
	}
	if got := out[at-1]; got != "- [ ] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(imp01)" {
		t.Fatalf("copy: %q\n%s", got, strings.Join(out, "\n"))
	}
	// a new day comes from the template
	out, day, at, err = ToNextDay([]string{"# Templates", "## Daily", "Outcomes:", "", "**2026-10-20:**", "- [ ] Call home"}, 6, newID)
	if err != nil || day != "2026-10-21" {
		t.Fatal(err, day)
	}
	if out[at-1] != "- [ ] Call home @id(new02)" || !strings.Contains(strings.Join(out, "\n"), "**2026-10-21:**\nOutcomes:") {
		t.Fatalf("new day:\n%s", strings.Join(out, "\n"))
	}
	for _, bad := range []int{7, 3, 99} {
		if _, _, _, err := ToNextDay(lines, bad, newID); err == nil {
			t.Errorf("line %d: no error", bad)
		}
	}
}
