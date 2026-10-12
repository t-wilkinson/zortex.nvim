package search

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
)

type fixtureResult struct {
	Type       string `json:"type"`
	Rel        string `json:"rel"`
	Lnum       int    `json:"lnum"`
	Breadcrumb string `json:"breadcrumb"`
	Score      int    `json:"score"`
	Child      bool   `json:"child"`
}

type fixtureCase struct {
	Prompt  string          `json:"prompt"`
	Mode    string          `json:"mode"`
	Results []fixtureResult `json:"results"`
}

func (r fixtureResult) String() string {
	if r.Type == "line" {
		return fmt.Sprintf("line %s:%d", r.Rel, r.Lnum)
	}
	return fmt.Sprintf("section %s:%d %q score=%d child=%v", r.Rel, r.Lnum, r.Breadcrumb, r.Score, r.Child)
}

func TestConformance(t *testing.T) {
	data, err := os.ReadFile("../../tests/fixtures/search.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []fixtureCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	ix, err := notes.Open("../../tests/fixtures/notes", ".zortex")
	if err != nil {
		t.Fatal(err)
	}
	idx := BuildAll(ix)
	for _, c := range cases {
		t.Run(c.Mode+":"+c.Prompt, func(t *testing.T) {
			var got []string
			for _, r := range Query(idx, c.Prompt, c.Mode) {
				fr := fixtureResult{Type: r.Type, Rel: r.Rel, Lnum: r.Lnum}
				if r.Type == "section" {
					fr.Breadcrumb, fr.Score, fr.Child = r.Breadcrumb, r.Score, r.Child
				}
				got = append(got, fr.String())
			}
			var want []string
			for _, r := range c.Results {
				want = append(want, r.String())
			}
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Errorf("prompt %q mode %s\n got (%d):\n  %s\nwant (%d):\n  %s", c.Prompt, c.Mode,
					len(got), strings.Join(got, "\n  "), len(want), strings.Join(want, "\n  "))
			}
		})
	}
}

func TestTokenize(t *testing.T) {
	got := Tokenize(`@@Proj #Habits :x *b 1.4\ -\ z a_b`)
	want := []Token{{"article", "proj"}, {"heading", "habits"}, {"label", "x"}, {"bold_heading", "b"}, {"general", "1.4 - z"}, {"general", "a b"}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func BenchmarkQuery(b *testing.B) {
	ix, _ := notes.Open("../../tests/fixtures/notes", ".zortex")
	idx := BuildAll(ix)
	for i := 0; i < b.N; i++ {
		Query(idx, "zortex search", "")
	}
}
