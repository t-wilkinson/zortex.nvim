package web

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

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
