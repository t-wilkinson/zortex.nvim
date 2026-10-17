package edit

import (
	"encoding/json"
	"os"
	"testing"
)

// tests/fixtures/autosize.json is written by the plugin (tests/gen_edits.lua
// from services/tasks.calendar_size).
func TestCalendarSizeConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/autosize.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Sizes map[string]float64 `json:"sizes"`
		Cases []struct {
			Name  string   `json:"name"`
			Lines []string `json:"lines"`
			Lnum  int      `json:"lnum"`
			Size  string   `json:"size"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		if got := CalendarSize(c.Lines, c.Lnum, fx.Sizes); got != c.Size {
			t.Errorf("%s: %q, want %q", c.Name, got, c.Size)
		}
	}
}
