package links

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
)

// tests/fixtures/resolve.json is written by the Lua resolver
// (nvim --headless -u NONE -l tests/gen_links.lua) over tests/fixtures/notes.
type resolveCase struct {
	Link    string `json:"link"`
	From    string `json:"from"`
	Lnum    int    `json:"lnum"`
	Error   string `json:"error"`
	Results []struct {
		Rel  string `json:"rel"`
		Lnum int    `json:"lnum"`
		Col  int    `json:"col"`
	} `json:"results"`
}

func TestConformance(t *testing.T) {
	data, err := os.ReadFile("../../tests/fixtures/resolve.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []resolveCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 50 {
		t.Fatalf("expected the resolve fixtures, found %d cases", len(cases))
	}
	live, err := notes.Open("../../tests/fixtures/notes", ".zortex")
	if err != nil {
		t.Fatal(err)
	}
	scanned, _ := notes.Open("../../tests/fixtures/notes", ".zortex")
	scanned.Scan()
	for _, mode := range []struct {
		name string
		ix   *notes.Index
	}{{"live", live}, {"scanned", scanned}} {
		t.Run(mode.name, func(t *testing.T) { conform(t, mode.ix, cases) })
	}
}

func conform(t *testing.T, ix *notes.Index, cases []resolveCase) {
	for _, c := range cases {
		name := c.Link
		if c.From != "" {
			name += " from " + c.From
		}
		if c.Lnum > 0 {
			name += fmt.Sprintf(":%d", c.Lnum)
		}
		t.Run(name, func(t *testing.T) {
			var opts Options
			if c.From != "" {
				opts.From = ix.Doc(c.From)
			}
			opts.Lnum = c.Lnum
			results, err := Resolve(ix, c.Link, opts)
			got := make([]string, len(results))
			for i, r := range results {
				got[i] = fmt.Sprintf("%s:%d:%d", r.Doc.Rel, r.Lnum, r.Col)
			}
			want := make([]string, len(c.Results))
			for i, r := range c.Results {
				want[i] = fmt.Sprintf("%s:%d:%d", r.Rel, r.Lnum, r.Col)
			}
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("results\n want %v\n got  %v (err %v)", want, got, err)
			}
			errText := ""
			if err != nil {
				errText = err.Error()
			}
			if errText != c.Error {
				t.Fatalf("error: want %q, got %q", c.Error, errText)
			}
		})
	}
}

func TestParse(t *testing.T) {
	d := Parse("[/#4 Learning & Education/:Fitness @a(1/2)/a + b]")
	if !d.Local || len(d.Components) != 3 {
		t.Fatalf("%+v", d)
	}
	if c := d.Components[0]; c.Type != "heading" || c.Text != "4 Learning & Education" {
		t.Errorf("typed components are never queries: %+v", c)
	}
	if c := d.Components[1]; c.Type != "label" || c.Text != "Fitness" {
		t.Errorf("attributes removed, '/' inside parentheses kept: %+v", c)
	}
	if c := d.Components[2]; c.Type != "or_query" || len(c.Tags) != 2 {
		t.Errorf("or query: %+v", c)
	}
}
