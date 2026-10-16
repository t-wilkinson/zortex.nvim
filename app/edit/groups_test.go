package edit

import (
	"encoding/json"
	"math"
	"os"
	"reflect"
	"testing"
)

// tests/fixtures/groups.json is written by the plugin (tests/gen_edits.lua
// from services/task_groups): the server groups tasks and cascades checks
// the same way.
func TestGroupsConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/groups.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Today   string             `json:"today"`
		Sizes   map[string]float64 `json:"sizes"`
		Default float64            `json:"default"`
		Groups  []struct {
			Name  string   `json:"name"`
			Lines []string `json:"lines"`
			Tasks []struct {
				Lnum       int     `json:"lnum"`
				Parent     int     `json:"parent"`
				Leaf       bool    `json:"leaf"`
				Hours      float64 `json:"hours"`
				Done       bool    `json:"done"`
				DoneDate   string  `json:"done_date"`
				OpenHours  float64 `json:"open_hours"`
				OpenLeaves int     `json:"open_leaves"`
				P          string  `json:"p"`
				I          string  `json:"i"`
			} `json:"tasks"`
		} `json:"groups"`
		Cascade []struct {
			Name  string     `json:"name"`
			Lnum  int        `json:"lnum"`
			Lines []string   `json:"lines"`
			Edits []LineEdit `json:"edits"`
		} `json:"cascade"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	hours := func(size string) (float64, bool) {
		h, ok := fx.Sizes[size]
		return h, ok
	}
	near := func(a, b float64) bool { return math.Abs(a-b) < 1e-5 }
	for _, c := range fx.Groups {
		got := Groups(c.Lines, 0, 0, hours, fx.Default)
		if len(got) != len(c.Tasks) {
			t.Errorf("%s: %d tasks, want %d", c.Name, len(got), len(c.Tasks))
		}
		for _, want := range c.Tasks {
			g := got[want.Lnum]
			if g == nil {
				t.Errorf("%s: no task at %d", c.Name, want.Lnum)
				continue
			}
			if g.Parent != want.Parent || g.Leaf != want.Leaf || !near(g.Hours, want.Hours) ||
				(g.Leaf && g.DoneEffective != want.Done) || g.DoneDate != want.DoneDate ||
				!near(g.OpenHours, want.OpenHours) || g.OpenLeaves != want.OpenLeaves || g.P != want.P || g.I != want.I {
				t.Errorf("%s, line %d:\n got %+v\nwant %+v", c.Name, want.Lnum, *g, want)
			}
		}
	}
	for _, c := range fx.Cascade {
		got := Cascade(c.Lines, c.Lnum, fx.Today)
		if len(got) == 0 && len(c.Edits) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, c.Edits) {
			t.Errorf("%s:\n got %+v\nwant %+v", c.Name, got, c.Edits)
		}
	}
}
