package links

import (
	"errors"
	"sort"
	"strconv"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Tag searches, @[scope/tags] (core/link tag_search): the components before
// the last "/" are a link giving where to look (none: the current note; "*":
// every note), the last one the tags: words are all of them, commas separate
// alternatives ("rust async, rl": rust and async, or rl; "@" optional). A line matches when it, or a section heading
// above it, carries the tags as bare @words.

// TagQuery is a parsed tag search.
type TagQuery struct {
	Scope  []string   // link components ("R", "#Rust"); nil: the current note or every note
	Local  bool       // the scope is a local link ("/#Heading/...")
	All    bool       // "*": every note
	Groups [][]string // any group, all of its tags (lower case, no "@")
}

// ParseTagSearch parses what is inside @[...].
func ParseTagSearch(content string) TagQuery {
	parts, local := SplitLink(content)
	query := ""
	if len(parts) > 0 {
		query = parts[len(parts)-1]
		parts = parts[:len(parts)-1]
	}
	var q TagQuery
	for _, group := range strings.Split(query, ",") {
		var terms []string
		// words split on ASCII white space, like Lua's %S+
		for _, term := range strings.FieldsFunc(group, isSpaceRune) {
			term = syntax.Lower(strings.TrimPrefix(term, "@"))
			if term != "" {
				terms = append(terms, term)
			}
		}
		if len(terms) > 0 {
			q.Groups = append(q.Groups, terms)
		}
	}
	q.All = len(parts) == 1 && parts[0] == "*"
	if len(parts) > 0 && !q.All {
		q.Scope = parts
	}
	q.Local = local
	return q
}

func isSpaceRune(r rune) bool { return r < 0x80 && isSpace(byte(r)) }

// lineTags are the bare @words on a line, with their 1-based columns.
func lineTags(d *notes.Document, lnum int) map[string]int {
	out := map[string]int{}
	syntax.Walk(d.Spans(lnum), func(sp *syntax.Span) {
		if sp.Type == "attribute" && !sp.HasValue {
			key := syntax.Lower(sp.Key)
			if _, ok := out[key]; !ok {
				out[key] = sp.S + 1
			}
		}
	})
	return out
}

// TagsAt lists the bare @tags of a line as a tag search sees them: its own
// (in order) and then those of the sections above it, nearest first.
func TagsAt(d *notes.Document, lnum int) []string {
	var out []string
	seen := map[string]bool{}
	add := func(l int) {
		tags := lineTags(d, l)
		keys := make([]string, 0, len(tags))
		for t := range tags {
			keys = append(keys, t)
		}
		sort.Slice(keys, func(i, j int) bool { return tags[keys[i]] < tags[keys[j]] })
		for _, t := range keys {
			if !seen[t] {
				seen[t] = true
				out = append(out, t)
			}
		}
	}
	add(lnum)
	for n := d.NodeAt(lnum); n != nil && !n.IsRoot() && n.Type != syntax.KindArticle; n = n.Parent {
		if n.Start != lnum {
			add(n.Start)
		}
	}
	return out
}

// TagSearch returns the lines a tag search matches, in the notes or
// sections its scope resolves to; Resolve calls it for "@[...]".
func TagSearch(ix *notes.Index, content string, opts Options) ([]Result, error) {
	q := ParseTagSearch(content)
	comp := Component{Type: "tag_search", Text: content, Original: "@[" + content + "]"}
	if len(q.Groups) == 0 {
		return nil, errors.New("No tags in " + comp.Original)
	}

	type span struct {
		doc  *notes.Document
		s, e int
	}
	var ranges []span
	switch {
	case q.All:
		for _, rel := range ix.Catalog().Files(false) {
			if d := ix.Doc(rel); d != nil {
				ranges = append(ranges, span{d, 1, len(d.Lines)})
			}
		}
	case q.Scope != nil:
		scope := strings.Join(q.Scope, "/")
		if q.Local {
			scope = "/" + scope
		}
		results, err := Resolve(ix, scope, opts)
		if len(results) == 0 {
			return nil, err
		}
		for _, r := range results {
			if r.Whole {
				ranges = append(ranges, span{r.Doc, 1, len(r.Doc.Lines)})
			} else {
				ranges = append(ranges, span{r.Doc, r.Lnum, r.End})
			}
		}
	default:
		if opts.From == nil {
			return nil, errors.New("No buffer to resolve a local link in")
		}
		ranges = []span{{opts.From, 1, len(opts.From.Lines)}}
	}

	var results []Result
	seen := map[string]bool{}
	for _, rg := range ranges {
		d := rg.doc
		inherited := map[int]map[string]bool{}
		var sectionTags func(n *notes.Node) map[string]bool
		sectionTags = func(n *notes.Node) map[string]bool {
			if n == nil || n.IsRoot() || n.Type == syntax.KindArticle {
				return nil
			}
			if tags, ok := inherited[n.Start]; ok {
				return tags
			}
			tags := map[string]bool{}
			for t := range sectionTags(n.Parent) {
				tags[t] = true
			}
			for t := range lineTags(d, n.Start) {
				tags[t] = true
			}
			inherited[n.Start] = tags
			return tags
		}
		end := rg.e
		if end > len(d.Lines) {
			end = len(d.Lines)
		}
		for lnum := rg.s; lnum <= end; lnum++ {
			switch d.Kind(lnum) {
			case "", syntax.KindBlank, syntax.KindArticle, syntax.KindTag:
				continue
			}
			key := d.Rel + ":" + strconv.Itoa(lnum)
			if d.InCode(lnum) || seen[key] {
				continue
			}
			own := lineTags(d, lnum)
			above := sectionTags(d.NodeAt(lnum))
			match := false
			for _, group := range q.Groups {
				match = true
				for _, t := range group {
					if _, ok := own[t]; !ok && !above[t] {
						match = false
						break
					}
				}
				if match {
					break
				}
			}
			if !match {
				continue
			}
			seen[key] = true
			col := 0
			for _, group := range q.Groups {
				for _, t := range group {
					if c, ok := own[t]; ok && (col == 0 || c < col) {
						col = c
					}
				}
			}
			if col == 0 {
				col = 1
			}
			results = append(results, Result{Doc: d, Lnum: lnum, Col: col, Component: comp})
		}
	}
	if len(results) == 0 {
		return nil, errors.New("No matches found for: " + comp.Original)
	}
	return results, nil
}
