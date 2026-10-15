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
			Name  string     `json:"name"`
			Today string     `json:"today"`
			From  string     `json:"from"`
			Lines []string   `json:"lines"`
			Edits []LineEdit `json:"edits"`
			At    int        `json:"at"`
			Add   []string   `json:"add"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		n := 0
		plan := Carry(c.Lines, c.Today, c.From, func() string { n++; return fmt.Sprintf("C%04d", n) })
		if len(plan.Edits) != len(c.Edits) || (len(c.Edits) > 0 && !reflect.DeepEqual(plan.Edits, c.Edits)) {
			t.Errorf("%s: edits\n got  %v\n want %v", c.Name, plan.Edits, c.Edits)
		}
		if plan.At != c.At || len(plan.Add) != len(c.Add) || (len(c.Add) > 0 && !reflect.DeepEqual(plan.Add, c.Add)) {
			t.Errorf("%s: at %d %q\n want at %d %q", c.Name, plan.At, plan.Add, c.At, c.Add)
		}
	}
}
