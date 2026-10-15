package web

import (
	"net/http"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Tag indexes: a label whose lines are all @[...] searches, or items that
// group them, shows on the web as rows of chips over one shared table.
//
//	Topics:
//	- AI @[rl, ai-model]          a chip, and a group of the chips under it
//	  - Reinforcement learning @[rl]
//	- Embedded                    a group: its chip searches everything under it
//	  - RTOS @[rtos embedded]
//
// The label's lines are the ones up to the first blank line. Every line is a
// list item (or a bare @[...] line) holding at most one search; an item
// without one must have items under it. Index labels separated only by
// blank lines share one widget. A chip's name is its text before the
// search, or the search itself. Choosing a chip loads its table under the
// rows and puts the search in the URL (#tags=rtos+embedded); nothing is
// chosen at first. The same rule is core/tag_index in the plugin, where gx
// on the label opens the index here.

// tiNode is one line of an index: a chip, a group of chips, or both.
type tiNode struct {
	lnum     int
	name     string
	query    string // what is inside @[...]; "" for a group without its own
	indent   int
	children []*tiNode
}

// tagIndex is one index label and its lines.
type tagIndex struct {
	lnum  int // the label
	last  int // its last line
	name  string
	nodes []*tiNode // top-level lines
}

// tagSearchOf is the one tag search on a line, nil when there is none, and
// ok=false when the line can't be part of an index (several searches, an
// embedded one).
func tagSearchOf(spans []syntax.Span) (sp *syntax.Span, ok bool) {
	for i := range spans {
		if spans[i].Type != "tag_search" {
			continue
		}
		if sp != nil || spans[i].Embed {
			return nil, false
		}
		sp = &spans[i]
	}
	return sp, true
}

// tagIndexAt reads the index label at lnum, or returns nil.
func tagIndexAt(d *notes.Document, ast *syntax.AST, lnum int) *tagIndex {
	if lnum < 1 || lnum > len(d.Lines) || d.InCode(lnum) {
		return nil
	}
	ld := ast.Lines[lnum-1]
	if ld.Kind != syntax.KindLabel || ld.Item != nil || ld.Indent > 0 {
		return nil
	}
	ix := &tagIndex{lnum: lnum, name: syntax.SectionText(d.Lines[lnum-1], syntax.KindLabel)}
	var all []*tiNode
	searches := 0
	for l := lnum + 1; l <= len(d.Lines); l++ {
		line := d.Lines[l-1]
		if strings.TrimSpace(line) == "" {
			break
		}
		ln := ast.Lines[l-1]
		spans := d.Spans(l)
		sp, ok := tagSearchOf(spans)
		if !ok {
			return nil
		}
		node := &tiNode{lnum: l, indent: ln.Indent}
		from := 0
		switch {
		case ln.Item != nil && (ln.Kind == syntax.KindItem || ln.Kind == syntax.KindLabel):
			if ln.Kind == syntax.KindLabel {
				// "- Embedded:": a group named by its key
				if sp != nil {
					return nil
				}
				node.name = ln.Item.Key
				break
			}
			from = ln.Item.ContentCol
		case ln.Kind == syntax.KindText && sp != nil:
			from = len(line) - len(strings.TrimLeft(line, " \t"))
		default:
			return nil
		}
		if sp != nil {
			searches++
			node.query = strings.TrimSpace(sp.Content)
			node.name = chipName(line[from:sp.S] + " " + line[sp.E:])
		} else if node.name == "" {
			node.name = chipName(line[from:])
		}
		ix.last = l
		all = append(all, node)
	}
	if searches == 0 {
		return nil
	}
	// nest by indent; an item without a search needs items under it
	var stack []*tiNode
	for i, n := range all {
		for len(stack) > 0 && stack[len(stack)-1].indent >= n.indent {
			stack = stack[:len(stack)-1]
		}
		if len(stack) == 0 {
			ix.nodes = append(ix.nodes, n)
		} else {
			p := stack[len(stack)-1]
			p.children = append(p.children, n)
		}
		stack = append(stack, n)
		if n.query == "" && (i+1 >= len(all) || all[i+1].indent <= n.indent) {
			return nil
		}
	}
	return ix
}

// chipName is a line's text as a chip's name: attributes and markup gone.
func chipName(text string) string {
	t := syntax.StripAttributes(text)
	t = strings.NewReplacer("**", "", "`", "").Replace(t)
	return strings.Join(strings.Fields(t), " ")
}

// tagQueryParts splits a search into its scope ("R/#Rust/", "/", "") and
// its tags ("rust async, rl").
func tagQueryParts(q string) (scope, tags string) {
	parts, _ := links.SplitLink(q)
	if len(parts) <= 1 {
		if strings.HasPrefix(strings.TrimSpace(q), "/") {
			return "/", strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(q), "/"))
		}
		return "", strings.TrimSpace(q)
	}
	i := strings.LastIndex(q, "/")
	return q[:i+1], strings.TrimSpace(q[i+1:])
}

// unionQuery is one search for any of qs ("rl", "ml" -> "rl, ml"), or ""
// when they look in different places.
func unionQuery(qs []string) string {
	if len(qs) == 0 {
		return ""
	}
	scope, _ := tagQueryParts(qs[0])
	var tags []string
	seen := map[string]bool{}
	for _, q := range qs {
		s, t := tagQueryParts(q)
		if s != scope {
			return ""
		}
		for _, alt := range strings.Split(t, ",") {
			alt = strings.Join(strings.Fields(alt), " ")
			if alt != "" && !seen[alt] {
				seen[alt] = true
				tags = append(tags, alt)
			}
		}
	}
	return scope + strings.Join(tags, ", ")
}

// queries are the searches of n and every line under it.
func (n *tiNode) queries() []string {
	var out []string
	if n.query != "" {
		out = append(out, n.query)
	}
	for _, c := range n.children {
		out = append(out, c.queries()...)
	}
	return out
}

// groupQuery is what choosing n searches: its own search, or the union of
// those under it.
func (n *tiNode) groupQuery() string {
	if n.query != "" {
		return n.query
	}
	return unionQuery(n.queries())
}

// tagIndexHTML renders adjacent index labels as one widget. lines are the
// ones the widget stands for (first..last), each kept as an anchor so links
// to them still land here.
func (r *noteRenderer) tagIndexHTML(idx []*tagIndex, first, last int) string {
	var b strings.Builder
	w := func(parts ...string) {
		for _, p := range parts {
			b.WriteString(p)
		}
	}
	counts := map[string]int{}
	count := func(q string) int {
		if n, ok := counts[q]; ok {
			return n
		}
		res, err := links.TagSearch(r.s.ix, q, links.Options{From: r.doc})
		n := 0
		if err == nil {
			n = len(res)
		}
		counts[q] = n
		return n
	}
	chip := func(cls, name, q string) {
		n := count(q)
		if n == 0 {
			cls += " none"
		}
		if name == "" {
			_, name = tagQueryParts(q)
		}
		w(`<a class="ti-chip`, cls, `" href="`, esc(r.s.linkURL("@["+q+"]", r.doc.Rel)), `" data-q="`, esc(q), `" title="@[`, esc(q), `]">`,
			esc(name), ` <span class="ti-n">`, itoa(n), `</span></a>`)
	}
	var chips func(ns []*tiNode)
	chips = func(ns []*tiNode) {
		for _, n := range ns {
			if q := n.groupQuery(); q != "" {
				chip("", n.name, q)
			}
			chips(n.children)
		}
	}

	w(`<div class="tag-index" id="L`, itoa(first), `" data-from="`, esc(r.doc.Rel), `">`)
	for l := first + 1; l <= last; l++ {
		w(`<span class="anchor" id="L`, itoa(l), `"></span>`)
	}
	w(`<div class="ti-rows">`)
	for _, ix := range idx {
		var loose, groups []*tiNode
		for _, n := range ix.nodes {
			if len(n.children) > 0 {
				groups = append(groups, n)
			} else {
				loose = append(loose, n)
			}
		}
		w(`<div class="ti-block">`)
		if len(loose) == 0 {
			w(`<div class="ti-caption">`, esc(ix.name), `</div>`)
		} else {
			// the label heads its own row; choosing it searches the whole row
			w(`<div class="ti-row">`)
			var qs []string
			for _, n := range loose {
				qs = append(qs, n.query)
			}
			if q := unionQuery(qs); q != "" && len(loose) > 1 {
				chip(" ti-head", ix.name, q)
			} else {
				w(`<span class="ti-head">`, esc(ix.name), `</span>`)
			}
			w(`<span class="ti-chips">`)
			chips(loose)
			w(`</span></div>`)
		}
		for _, g := range groups {
			w(`<div class="ti-row">`)
			if q := g.groupQuery(); q != "" {
				chip(" ti-head", g.name, q)
			} else {
				w(`<span class="ti-head">`, esc(g.name), `</span>`)
			}
			w(`<span class="ti-chips">`)
			chips(g.children)
			w(`</span></div>`)
		}
		w(`</div>`)
	}
	w(`</div><div class="ti-table" aria-live="polite"></div></div>`)
	return b.String()
}

// tagIndexRun reads the index labels starting at lnum, with the ones after
// it that only blank lines separate from it. nil: lnum isn't an index.
func (r *noteRenderer) tagIndexRun(lnum int) (idx []*tagIndex, last int) {
	if r.md != nil || r.slides {
		return nil, 0
	}
	for l := lnum; l <= len(r.doc.Lines); {
		ix := tagIndexAt(r.doc, r.ast, l)
		if ix == nil {
			break
		}
		idx = append(idx, ix)
		last = ix.last
		next := ix.last + 1
		for next <= len(r.doc.Lines) && strings.TrimSpace(r.doc.Lines[next-1]) == "" {
			next++
		}
		l = next
	}
	return idx, last
}

// apiTagTable is the table of one tag search, for a tag index's chips:
// GET /api/tagtable?q=rtos+embedded&from=hub.zortex
func (s *Server) apiTagTable(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		http.Error(w, "q is required", http.StatusBadRequest)
		return
	}
	var from *notes.Document
	if rel := r.URL.Query().Get("from"); rel != "" {
		from = s.ix.Doc(rel)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	head := `<p class="ti-for dim"><a href="` + esc(s.linkURL("@["+q+"]", relOf(from))) + `">` + tagSearchText(q) + `</a></p>`
	_, _ = w.Write([]byte(head + s.tagTableHTML(from, q)))
}

func relOf(d *notes.Document) string {
	if d == nil {
		return ""
	}
	return d.Rel
}
