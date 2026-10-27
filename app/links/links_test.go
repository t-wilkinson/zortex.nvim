package links

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
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
	d := Parse("[/#4 Learning & Education/:Fitness @a(1/2)/%a b]")
	if !d.Local || len(d.Components) != 3 {
		t.Fatalf("%+v", d)
	}
	if c := d.Components[0]; c.Type != "heading" || c.Text != "4 Learning & Education" {
		t.Errorf("heading keeps its &: %+v", c)
	}
	if c := d.Components[1]; c.Type != "label" || c.Text != "Fitness" {
		t.Errorf("attributes removed, '/' inside parentheses kept: %+v", c)
	}
	if c := d.Components[2]; c.Type != "query" || c.Text != "a b" {
		t.Errorf("query: %+v", c)
	}
}

// Attribute terms: @[status(reading)], and a reference's author and year.
func TestAttributeTermsInTagSearches(t *testing.T) {
	q := ParseTagSearch("*/author(Van Rossum) year(2020), ref(Smith,  2020)")
	if len(q.Groups) != 2 || q.Groups[0][0] != "author(van rossum)" || q.Groups[0][1] != "year(2020)" || q.Groups[1][0] != "ref(smith,2020)" {
		t.Fatalf("%q", q.Groups)
	}
	line := "- notes @ref(Smith & Jones et al., 2019a; Lee, 2021) @status(Reading)"
	sp := syntax.Inline(line, 2, len(line))
	terms := AttributeTerms(sp)
	for _, want := range []string{"ref(smith & jones et al.,2019a;lee,2021)", "author(smith & jones et al.)", "author(smith & jones)", "author(smith)", "author(jones)", "year(2019a)", "author(lee)", "year(2021)", "status(reading)"} {
		if _, ok := terms[want]; !ok {
			t.Errorf("no %q in %v", want, terms)
		}
	}
}
