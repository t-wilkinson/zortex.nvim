package edit

import (
	"encoding/json"
	"os"
	"testing"
)

// The Lua implementation's results (tests/gen_edits.lua) are the spec.
func TestConformance(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/edits.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Today string `json:"today"`
		ID    string `json:"id"`
		Cases []struct {
			Line   string  `json:"line"`
			Op     string  `json:"op"`
			Result *string `json:"result"`
			Error  bool    `json:"error"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		got, err := Line(c.Line, c.Op, fx.Today, func() string { return fx.ID })
		if c.Error {
			if err == nil {
				t.Errorf("%s %q: want an error, got %q", c.Op, c.Line, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s %q: %v", c.Op, c.Line, err)
			continue
		}
		if c.Result == nil || got != *c.Result {
			t.Errorf("%s %q:\n got  %q\n want %v", c.Op, c.Line, got, *c.Result)
		}
	}
}

func TestNewID(t *testing.T) {
	a, b := NewID(), NewID()
	if len(a) != 5 || a == b {
		t.Fatalf("%q %q", a, b)
	}
}
