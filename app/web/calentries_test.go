package web

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
)

// tests/fixtures/calendar.json is Neovim's reading of one calendar
// (tests/calendar_cases.lua, written by tests/gen_edits.lua from
// stores/calendar): the web calendar must see the same entries.
func TestCalendarEntriesConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/calendar.json")
	if err != nil {
		t.Fatal(err)
	}
	type row struct {
		Lnum  int    `json:"lnum"`
		Time  string `json:"time"`
		End   string `json:"end"`
		Text  string `json:"text"`
		Task  bool   `json:"task"`
		Done  bool   `json:"done"`
		Moved bool   `json:"moved"`
		Depth int    `json:"depth"`
	}
	var fx struct {
		Lines []string         `json:"lines"`
		Days  map[string][]row `json:"days"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	got := calendarEntries(notes.FromLines("calendar.zortex", fx.Lines), "", "")
	if len(got) != len(fx.Days) {
		t.Errorf("%d days, want %d", len(got), len(fx.Days))
	}
	for date, want := range fx.Days {
		var rows []row
		for _, e := range got[date] {
			rows = append(rows, row{e.Lnum, e.Time, e.End, e.Text, e.Task, e.Done, e.Moved, e.Depth})
		}
		if !reflect.DeepEqual(rows, want) {
			for i := range want {
				if i >= len(rows) || rows[i] != want[i] {
					var g row
					if i < len(rows) {
						g = rows[i]
					}
					t.Errorf("%s: got  %+v\n            want %+v", date, g, want[i])
				}
			}
			if len(rows) > len(want) {
				t.Errorf("%s: %d extra entries", date, len(rows)-len(want))
			}
		}
	}
}

// The top of the same calendar: templates, what the repeating rules put on
// each day, and the copies ticking one writes (calendar.json, from the
// plugin's services/calendar_rules).
func TestCalendarRulesConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/calendar.json")
	if err != nil {
		t.Fatal(err)
	}
	type occ struct {
		Rule int    `json:"rule"`
		Time string `json:"time"`
		End  string `json:"end"`
		Text string `json:"text"`
		Task bool   `json:"task"`
		Done bool   `json:"done"`
		Copy int    `json:"copy"`
	}
	var fx struct {
		Lines       []string            `json:"lines"`
		Templates   map[string][]string `json:"templates"`
		Occurrences map[string][]occ    `json:"occurrences"`
		Copies      []struct {
			Lnum              int
			Date, Today, Line string
		} `json:"copies"`
		ID string `json:"id"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	for date, want := range fx.Templates {
		if got := edit.Template(fx.Lines, date); !reflect.DeepEqual(got, want) {
			t.Errorf("template %s: %q, want %q", date, got, want)
		}
	}
	doc := notes.FromLines("calendar.zortex", fx.Lines)
	rules := edit.Rules(fx.Lines)
	all := calendarEntries(doc, "", "")
	forCopies := forCopiesOf(doc, all)
	for day := 1; day <= 31; day++ {
		date := fmt.Sprintf("2026-10-%02d", day)
		var got []occ
		for _, e := range occurrences(doc, rules, all[date], forCopies, date) {
			got = append(got, occ{e.Lnum, e.Time, e.End, e.Text, e.Task, e.Done, e.Copy})
		}
		if want := fx.Occurrences[date]; !reflect.DeepEqual(got, want) {
			t.Errorf("%s:\n got  %+v\n want %+v", date, got, want)
		}
	}
	for _, c := range fx.Copies {
		r := edit.RuleOf(fx.Lines[c.Lnum-1], c.Lnum)
		got, err := r.DoneCopy(c.Date, c.Today, func() string { return fx.ID })
		if err != nil || got != c.Line {
			t.Errorf("copy of %d for %s: %q, want %q (%v)", c.Lnum, c.Date, got, c.Line, err)
		}
	}
}
