package edit

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// Days, months and where a new day goes, as Neovim's
// services/calendar_days (tests/fixtures/caldays.json, from
// tests/gen_edits.lua).
func TestCalendarDaysConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/caldays.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name   string   `json:"name"`
			Lines  []string `json:"lines"`
			Days   []Day    `json:"days"`
			Months []Month  `json:"months"`
			Place  []struct {
				Date    string   `json:"date"`
				Group   bool     `json:"group"`
				At      int      `json:"at"`
				Lines   []string `json:"lines"`
				Heading int      `json:"heading"`
			} `json:"place"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		if got := Days(c.Lines); !(len(got) == 0 && len(c.Days) == 0) && !reflect.DeepEqual(got, c.Days) {
			t.Errorf("%s: days\n got  %+v\n want %+v", c.Name, got, c.Days)
		}
		if got := MonthsOf(c.Lines); !(len(got) == 0 && len(c.Months) == 0) && !reflect.DeepEqual(got, c.Months) {
			t.Errorf("%s: months\n got  %+v\n want %+v", c.Name, got, c.Months)
		}
		for _, p := range c.Place {
			got := InsertDay(c.Lines, p.Date, []string{"- new"}, p.Group, "")
			want := DayInsert{At: p.At, Lines: p.Lines, Heading: p.Heading}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("%s: %s (group %v)\n got  %q\n want %q", c.Name, p.Date, p.Group, got, want)
			}
		}
	}
}

func TestMonthHeading(t *testing.T) {
	for line, want := range map[string]string{
		"# October 2026": "2026-10", "## Oct 2026": "2026-10", "# Sept. 2026": "", "# Sep. 2026": "2026-09",
		"### 2026-03": "2026-03", "# 2026-13": "", "#October 2026": "", "# October": "", "- # October 2026": "",
	} {
		got, _, _ := MonthHeading(line)
		if got != want {
			t.Errorf("MonthHeading(%q) = %q, want %q", line, got, want)
		}
	}
	if got := MonthHeadingLine("2026-03", 2); got != "## March 2026" {
		t.Errorf("MonthHeadingLine = %q", got)
	}
}
