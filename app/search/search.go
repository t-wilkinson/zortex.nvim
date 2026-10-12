// Package search is the structural search: words match a section's path in
// order (earlier words on ancestors, the last word on the section itself),
// results are ranked by match quality and hierarchy, grouped by file, then
// followed by lines containing every word. It ports services/search from the
// plugin; search_test.go checks it against tests/fixtures/search.json.
//
// Search history boosts (services/search_history) are not ported yet: scores
// here are the plugin's scores with no history.
package search

import (
	"sort"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Rule allows a section type, optionally up to a heading level.
type Rule struct {
	Type     string
	MaxLevel int // 0: any level
}

// Config mirrors Config.ui.search in the plugin.
type Config struct {
	DefaultMode string
	MaxResults  int
	// TokenFilters[n-1]: section types that may be results when the prompt
	// has n words (the last entry applies beyond). Typed words bypass it.
	TokenFilters [][]Rule
}

// DefaultConfig matches the plugin's defaults.
func DefaultConfig() Config {
	return Config{
		DefaultMode: "section",
		MaxResults:  500,
		TokenFilters: [][]Rule{
			{{Type: "article"}, {Type: "heading", MaxLevel: 1}},
			{{Type: "article"}, {Type: "heading", MaxLevel: 3}},
			{{Type: "article"}, {Type: "heading"}, {Type: "bold_heading"}, {Type: "label"}},
		},
	}
}

// =============================================================================
// Index
// =============================================================================

type element struct {
	typ   string
	texts []string // lower-cased: the text, then article aliases
}

type section struct {
	node       *notes.Node
	rel        string
	breadcrumb string
	path       []element
	rootLevel  bool // no heading above it
}

type line struct {
	rel   string
	lnum  int
	text  string
	lower string
}

type file struct {
	rel      string
	archived bool
	sections []section
	lines    []line
}

// Index is the searchable form of a set of notes; build it once, query it
// on every keystroke.
type Index struct{ files []file }

// Build indexes notes (rel paths, in the order line results should come
// out). Notes tagged @Ignore are skipped.
func Build(ix *notes.Index, rels []string) *Index {
	out := &Index{}
	for _, rel := range rels {
		doc := ix.Doc(rel)
		if doc == nil || doc.HasTag("Ignore") {
			continue
		}
		f := file{rel: rel, archived: ix.IsArchived(rel)}
		structural := map[int]bool{}
		for _, n := range doc.Sections() {
			structural[n.Start] = true
			rootLevel := true
			for p := n.Parent; p != nil && !p.IsRoot(); p = p.Parent {
				if p.Type == "heading" {
					rootLevel = false
					break
				}
			}
			var path []element
			for _, p := range n.Path() {
				texts := []string{syntax.Lower(p.Text)}
				for _, alias := range p.Names {
					texts = append(texts, syntax.Lower(alias))
				}
				path = append(path, element{typ: p.Type, texts: texts})
			}
			f.sections = append(f.sections, section{node: n, rel: rel, breadcrumb: n.Breadcrumb(" › "), path: path, rootLevel: rootLevel})
		}
		for i, text := range doc.Lines {
			lnum := i + 1
			if !structural[lnum] && syntax.Trim(text) != "" {
				f.lines = append(f.lines, line{rel: rel, lnum: lnum, text: text, lower: syntax.Lower(text)})
			}
		}
		out.files = append(out.files, f)
	}
	return out
}

// BuildAll indexes every note, archived ones included.
func BuildAll(ix *notes.Index) *Index { return Build(ix, ix.All()) }

// =============================================================================
// Tokens
// =============================================================================

// Token is a search word: Type is general, article (@@), heading (#),
// label (:) or bold_heading (*).
type Token struct {
	Type string
	Text string
}

var prefixes = []struct{ prefix, typ string }{
	{"@@", "article"}, {"#", "heading"}, {":", "label"}, {"*", "bold_heading"},
}

// Tokenize splits a prompt into typed, lower-cased words. "\ " and "_" are
// spaces inside a word.
func Tokenize(prompt string) []Token {
	escaped := strings.ReplaceAll(prompt, "\\ ", "\x00")
	var out []Token
	for _, word := range fieldsLua(escaped) {
		word = strings.ReplaceAll(word, "\x00", " ")
		word = syntax.Lower(strings.ReplaceAll(word, "_", " "))
		typ := "general"
		for _, p := range prefixes {
			if strings.HasPrefix(word, p.prefix) {
				typ = p.typ
				word = word[len(p.prefix):]
				if typ == "heading" {
					word = strings.TrimLeft(word, "#")
				}
				break
			}
		}
		out = append(out, Token{Type: typ, Text: word})
	}
	return out
}

// fieldsLua splits on Lua %s whitespace (ASCII), like gmatch("%S+").
func fieldsLua(s string) []string {
	var out []string
	start := -1
	for i := 0; i < len(s); i++ {
		sp := s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\v' || s[i] == '\f' || s[i] == '\r'
		if sp {
			if start >= 0 {
				out = append(out, s[start:i])
				start = -1
			}
		} else if start < 0 {
			start = i
		}
	}
	if start >= 0 {
		out = append(out, s[start:])
	}
	return out
}

// =============================================================================
// Matching and ranking
// =============================================================================

func typeOK(tok Token, typ string) bool {
	return tok.Type == "general" || tok.Type == typ
}

// tokenScore: exact 3, prefix 2, substring 1, 0 = no match. A bare prefix
// ("@@") matches any element of its type.
func tokenScore(tok Token, el element) int {
	if !typeOK(tok, el.typ) {
		return 0
	}
	if tok.Text == "" {
		return 1
	}
	best := 0
	for _, text := range el.texts {
		q := 0
		switch {
		case text == tok.Text:
			q = 3
		case strings.HasPrefix(text, tok.Text):
			q = 2
		case strings.Contains(text, tok.Text):
			q = 1
		}
		if q > best {
			best = q
		}
	}
	return best
}

// pathMatch is the best total word quality matching the words along path in
// order with the last word on the last element (0 when there is no match).
// Consecutive words may share an element.
func pathMatch(path []element, tokens []Token) int {
	n := len(path)
	if n == 0 {
		return 0
	}
	prev := make([]int, n) // 0 = no match
	for i := 0; i < n; i++ {
		prev[i] = tokenScore(tokens[0], path[i])
	}
	for j := 1; j < len(tokens); j++ {
		cur := make([]int, n)
		run := 0
		for i := 0; i < n; i++ {
			if prev[i] > run {
				run = prev[i]
			}
			if q := tokenScore(tokens[j], path[i]); run > 0 && q > 0 {
				cur[i] = run + q
			}
		}
		prev = cur
	}
	return prev[n-1]
}

func typeBonus(n *notes.Node) int {
	switch n.Type {
	case "article":
		return 2000
	case "heading":
		return 1000 - n.Level*50
	case "bold_heading":
		return 400
	case "label":
		return 300
	}
	return 0
}

// Result is a section or a matching line.
type Result struct {
	Type       string // "section" or "line"
	Rel        string
	Lnum       int
	Node       *notes.Node // sections
	Breadcrumb string      // sections
	Score      int         // sections
	Child      bool        // listed because its parent matched
	Archived   bool
	Line       string // lines
	Rank       int    // 1-based position in the results
}

func (c Config) filterFor(n int) func(s *section) bool {
	if len(c.TokenFilters) == 0 {
		return func(*section) bool { return true }
	}
	idx := n
	if idx < 1 {
		idx = 1
	}
	if idx > len(c.TokenFilters) {
		idx = len(c.TokenFilters)
	}
	rules := c.TokenFilters[idx-1]
	allows := func(typ string, level int) bool {
		for _, r := range rules {
			if r.Type == typ && (r.MaxLevel == 0 || level <= r.MaxLevel) {
				return true
			}
		}
		return false
	}
	return func(s *section) bool {
		if s.rootLevel && (s.node.Type == "bold_heading" || s.node.Type == "label") {
			return allows("heading", 1)
		}
		return allows(s.node.Type, s.node.Level)
	}
}

type group struct {
	archived bool
	best     int
	results  []Result
}

func matchSections(idx *Index, tokens []Token, allowed func(*section) bool, withChildren bool) []Result {
	var groups []group
	for _, f := range idx.files {
		g := group{archived: f.archived}
		haveBest := false
		matched := map[*notes.Node]int{}
		for k := range f.sections {
			s := &f.sections[k]
			score, ok := 0, false
			if len(tokens) == 0 {
				if len(s.path) == 1 && allowed(s) {
					score, ok = typeBonus(s.node), true
				}
			} else if allowed(s) {
				if q := pathMatch(s.path, tokens); q > 0 {
					score, ok = q*100+typeBonus(s.node), true
				}
			}
			if ok {
				matched[s.node] = score
				g.results = append(g.results, Result{Type: "section", Rel: s.rel, Lnum: s.node.Start, Node: s.node, Breadcrumb: s.breadcrumb, Score: score, Archived: f.archived})
				if !haveBest || score > g.best {
					g.best, haveBest = score, true
				}
			} else if withChildren && len(tokens) > 0 && s.node.Parent != nil {
				if ps, ok := matched[s.node.Parent]; ok {
					g.results = append(g.results, Result{Type: "section", Rel: s.rel, Lnum: s.node.Start, Node: s.node, Breadcrumb: s.breadcrumb, Score: ps, Child: true, Archived: f.archived})
				}
			}
		}
		if len(g.results) > 0 {
			groups = append(groups, g)
		}
	}
	sort.SliceStable(groups, func(i, j int) bool {
		a, b := groups[i], groups[j]
		if a.archived != b.archived {
			return !a.archived
		}
		if a.best != b.best {
			return a.best > b.best
		}
		return a.results[0].Rel < b.results[0].Rel
	})
	var out []Result
	for _, g := range groups {
		out = append(out, g.results...)
	}
	return out
}

func matchLines(idx *Index, tokens []Token) []Result {
	if len(tokens) == 0 {
		return nil
	}
	var out []Result
	for _, f := range idx.files {
		for _, ln := range f.lines {
			all := true
			for _, t := range tokens {
				if !strings.Contains(ln.lower, t.Text) {
					all = false
					break
				}
			}
			if all {
				out = append(out, Result{Type: "line", Rel: ln.rel, Lnum: ln.lnum, Line: ln.text, Archived: f.archived})
			}
		}
	}
	return out
}

// Query searches the index. mode "section" (default): sections (with their
// direct sub-sections), then lines with every word. "article": articles only.
func (c Config) Query(idx *Index, prompt, mode string) []Result {
	if mode == "" {
		mode = c.DefaultMode
	}
	tokens := Tokenize(prompt)
	var results []Result
	if mode == "article" {
		results = matchSections(idx, tokens, func(s *section) bool { return s.node.Type == "article" }, false)
	} else {
		typed := false
		for _, t := range tokens {
			typed = typed || t.Type != "general"
		}
		allowed := c.filterFor(len(tokens))
		if typed {
			allowed = func(*section) bool { return true }
		}
		results = matchSections(idx, tokens, allowed, true)
		results = append(results, matchLines(idx, tokens)...)
	}
	if c.MaxResults > 0 && len(results) > c.MaxResults {
		results = results[:c.MaxResults]
	}
	for i := range results {
		results[i].Rank = i + 1
	}
	return results
}

// Query searches with the default configuration.
func Query(idx *Index, prompt, mode string) []Result {
	return DefaultConfig().Query(idx, prompt, mode)
}
