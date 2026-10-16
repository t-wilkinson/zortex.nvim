package web

import (
	"sort"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Tags that go nowhere, on /broken next to the broken links (computed when
// the page is asked for; the plugin's link_index.tag_problems):
//
//	searches  tag searches (@[...]) that find nothing
//	links     [@Tag] links to a header tag no note has
//	orphans   bare tags on lines that no tag search asks for (bare
//	          attributes like @p1, @sm, @2h are not tags)

type tagSearchProblem struct {
	From string
	Lnum int
	Text string
	Why  string
}

type orphanTag struct {
	Tag   string
	Count int
	From  string
	Lnum  int
}

type tagProblems struct {
	Searches []tagSearchProblem
	Links    []Broken
	Orphans  []orphanTag
}

// isTagLink: a broken [@Tag] link (not a task-id problem, "@id(…)").
func isTagLink(b Broken) bool {
	d := strings.TrimSpace(b.Def)
	return strings.HasPrefix(d, "@") && !strings.Contains(d, "(")
}

func (s *Server) tagProblems(broken []Broken) tagProblems {
	var out tagProblems
	asked := map[string]bool{}
	used := map[string]*orphanTag{}
	for _, rel := range s.ix.Catalog().Files(false) {
		d := s.ix.Doc(rel)
		if d == nil {
			continue
		}
		for i, line := range d.Lines {
			lnum := i + 1
			if !strings.Contains(line, "@") || d.InCode(lnum) {
				continue
			}
			syntax.Walk(d.Spans(lnum), func(sp *syntax.Span) {
				switch {
				case sp.Type == "tag_search":
					for _, g := range links.ParseTagSearch(sp.Content).Groups {
						for _, t := range g {
							if !strings.HasPrefix(t, "is:") {
								asked[t] = true
							}
						}
					}
					res, err := links.TagSearch(s.ix, sp.Content, links.Options{From: d, Lnum: lnum})
					if err != nil || len(res) == 0 {
						why := "No matches"
						if err != nil {
							why = err.Error()
						}
						out.Searches = append(out.Searches, tagSearchProblem{From: rel, Lnum: lnum, Text: "@[" + sp.Content + "]", Why: why})
					}
				case sp.Type == "attribute" && !sp.HasValue:
					key := syntax.Lower(sp.Key)
					if links.IsAttributeWord(key) {
						return
					}
					u := used[key]
					if u == nil {
						u = &orphanTag{Tag: key, From: rel, Lnum: lnum}
						used[key] = u
					}
					u.Count++
				}
			})
		}
	}
	for _, b := range broken {
		if isTagLink(b) {
			out.Links = append(out.Links, b)
		}
	}
	for key, u := range used {
		if !asked[key] {
			out.Orphans = append(out.Orphans, *u)
		}
	}
	sort.Slice(out.Orphans, func(i, j int) bool {
		if out.Orphans[i].Count != out.Orphans[j].Count {
			return out.Orphans[i].Count > out.Orphans[j].Count
		}
		return out.Orphans[i].Tag < out.Orphans[j].Tag
	})
	return out
}
