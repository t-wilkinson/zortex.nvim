package edit

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"
)

// services/planner.carry (tests/gen_edits.lua) is the spec.
func TestCarryConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/carry.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name    string     `json:"name"`
			Today   string     `json:"today"`
			From    string     `json:"from"`
			Lines   []string   `json:"lines"`
			Group   bool       `json:"group"`
			Edits   []LineEdit `json:"edits"`
			Inserts []Insert   `json:"inserts"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	defer SetGroupDays(true)
	for _, c := range fx.Cases {
		n := 0
		SetGroupDays(c.Group)
		plan := Carry(c.Lines, c.Today, c.From, func() string { n++; return fmt.Sprintf("C%04d", n) })
		if len(plan.Edits) != len(c.Edits) || (len(c.Edits) > 0 && !reflect.DeepEqual(plan.Edits, c.Edits)) {
			t.Errorf("%s: edits\n got  %v\n want %v", c.Name, plan.Edits, c.Edits)
		}
		if len(plan.Inserts) != len(c.Inserts) || (len(c.Inserts) > 0 && !reflect.DeepEqual(plan.Inserts, c.Inserts)) {
			t.Errorf("%s: inserts\n got  %q\n want %q", c.Name, plan.Inserts, c.Inserts)
		}
	}
}

func TestDateHeading(t *testing.T) {
	for line, want := range map[string]string{
		"2026-10-21:":      "2026-10-21",
		"**2026-10-21:**":  "2026-10-21",
		"**2026-10-21:** ": "2026-10-21",
		"**2026-10-21**:":  "",
		"**2026-10-21:":    "",
		"  2026-10-21:":    "",
		"2026-10-21: x":    "",
	} {
		got, ok := DateHeading(line)
		if got != want || ok != (want != "") {
			t.Errorf("%q: %q %v", line, got, ok)
		}
	}
	if DateHeadingLine("2026-10-21") != "**2026-10-21:**" {
		t.Error(DateHeadingLine("2026-10-21"))
	}
}
