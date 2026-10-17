package search

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

// The web app's own history (search_history.json in -data, never the
// notes' .z/): opening a place from search ranks it higher, never above a
// better word match.
func TestHistoryRanks(t *testing.T) {
	dir := t.TempDir()
	for name, text := range map[string]string{"a.zortex": "@@Alpha\n\n# Kitchen\n", "b.zortex": "@@Beta\n\n# Kitchen\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ix, err := notes.Open(dir, ".zortex")
	if err != nil {
		t.Fatal(err)
	}
	ix.Scan()
	idx := BuildAll(ix)
	path := filepath.Join(t.TempDir(), "search_history.json")
	h, err := OpenHistory(path)
	if err != nil {
		t.Fatal(err)
	}
	cfg := DefaultConfig()
	cfg.History = h
	first := func(prompt string) string {
		r := cfg.Query(idx, prompt, "")
		if len(r) == 0 {
			return ""
		}
		return r[0].Rel
	}
	if got := first("kitchen"); got != "a.zortex" {
		t.Fatalf("tie: %s first", got)
	}
	now := time.Now()
	if err := h.Record("b.zortex", []string{"Beta › Kitchen", "Beta"}, now); err != nil {
		t.Fatal(err)
	}
	if got := first("kitchen"); got != "b.zortex" {
		t.Errorf("after opening b, %s comes first", got)
	}
	// a better word match still wins: "alpha kitchen" only matches a
	if got := first("alpha kitchen"); got != "a.zortex" {
		t.Errorf("alpha kitchen: %s", got)
	}
	// kept on disk, and decayed: two months later it's forgotten
	h2, err := OpenHistory(path)
	if err != nil {
		t.Fatal(err)
	}
	if v := h2.Opened("b.zortex", now); v < 0.99 {
		t.Errorf("reloaded score %.2f", v)
	}
	if v := h2.Opened("b.zortex", now.AddDate(0, 2, 0)); v > 0.01 {
		t.Errorf("score after two months %.3f", v)
	}
}
