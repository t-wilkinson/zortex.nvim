package web

import (
	"html/template"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The link graph, with the structure as its backbone.
//
// A note page shows the note's neighbourhood: the notes whose structure
// lists it (above), the notes its own # Structure section lists (below),
// and the other notes it links to (left) and that link to it (right).
// /graph shows the whole structure as columns of cards, one per top-level
// section of the Structure note (and per hub the tree doesn't reach), each
// hub note expanded with its own # Structure section; hovering a note marks
// its other links, a tag marks its notes, and a filter narrows it all.

// neighbours of a note, each list in order without repeats.
type neighbours struct {
	Parents    []string          // notes whose structure lists rel
	Category   map[string]string // parent -> the section rel is listed under
	Children   []string          // notes rel's structure lists
	LinksTo    []string          // other notes rel links to
	LinkedFrom []string          // other notes linking to rel
	Mutual     map[string]bool   // in LinksTo and linking back
}

func (s *Server) neighboursOf(rel string) neighbours {
	snap := s.current()
	info := snap.structure
	nb := neighbours{Category: map[string]string{}, Mutual: map[string]bool{}}
	shown := map[string]bool{rel: true}
	addTo := func(list *[]string, r string) bool {
		if shown[r] || s.ix.IsArchived(r) {
			return false
		}
		shown[r] = true
		*list = append(*list, r)
		return true
	}
	back := snap.backlinks[rel]
	for _, b := range back {
		if b.FromNote && info.inStructure(b.From, b.Lnum) && addTo(&nb.Parents, b.From) {
			nb.Category[b.From] = s.categoryOf(b.From, b.Lnum)
		}
	}
	for _, l := range snap.forward[rel] {
		if info.inStructure(rel, l.Lnum) {
			addTo(&nb.Children, l.To)
		}
	}
	linksBack := map[string]bool{}
	for _, b := range back {
		if b.FromNote {
			linksBack[b.From] = true
		}
	}
	for _, l := range snap.forward[rel] {
		if addTo(&nb.LinksTo, l.To) && linksBack[l.To] {
			nb.Mutual[l.To] = true
		}
	}
	for _, b := range back {
		if b.FromNote {
			addTo(&nb.LinkedFrom, b.From)
		}
	}
	return nb
}

// categoryOf is the section a structure line is in, below the note's title
// and its # Structure heading: "Library › Cooking".
func (s *Server) categoryOf(rel string, lnum int) string {
	doc := s.ix.Doc(rel)
	if doc == nil {
		return ""
	}
	n := doc.NodeAt(lnum)
	var parts []string
	for _, p := range n.Path() {
		if p.Type == "article" || (p.Level == 1 && strings.EqualFold(strings.TrimSpace(p.Text), structureName)) {
			continue
		}
		if p.Start == lnum {
			continue // the line itself is a label
		}
		parts = append(parts, p.Text)
	}
	return strings.Join(parts, " › ")
}

// ---------------------------------------------------------------------------
// The local graph (SVG)
// ---------------------------------------------------------------------------

const (
	gW      = 720 // viewBox width
	gNodeW  = 156
	gNodeH  = 30
	gPerRow = 4
	gMaxRow = 8  // parents, children shown (then "+N more")
	gMaxCol = 7  // links to / from shown
	gChars  = 22 // label length
)

type gNode struct {
	Rel, Label, Sub, Class string
	X, Y                   int // top-left
}

func (n gNode) cx() int { return n.X + gNodeW/2 }
func (n gNode) cy() int { return n.Y + gNodeH/2 }

func clip(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}

// localGraph renders rel's neighbourhood, or "" when it has none.
func (s *Server) localGraph(rel string) template.HTML {
	nb := s.neighboursOf(rel)
	if len(nb.Parents)+len(nb.Children)+len(nb.LinksTo)+len(nb.LinkedFrom) == 0 {
		return ""
	}
	var nodes []gNode
	node := func(r, class, sub string) gNode {
		return gNode{Rel: r, Label: clip(s.noteTitle(r), gChars), Sub: clip(sub, gChars+4), Class: class}
	}
	more := func(n int) gNode { return gNode{Label: "+" + itoa(n) + " more", Class: "more"} }
	// rows of up to gPerRow nodes, centred
	rows := func(list []gNode, y, rowH int) int {
		for i := 0; i < len(list); i += gPerRow {
			row := list[i:min(i+gPerRow, len(list))]
			for j := range row {
				x := gW/2 + (2*j-len(row)+1)*(gNodeW+16)/2 - gNodeW/2
				row[j].X, row[j].Y = x, y
				nodes = append(nodes, row[j])
			}
			y += rowH
		}
		return y
	}
	limit := func(rels []string, max int, mk func(string) gNode) []gNode {
		var out []gNode
		for i, r := range rels {
			if i == max-1 && len(rels) > max {
				out = append(out, more(len(rels)-i))
				break
			}
			out = append(out, mk(r))
		}
		return out
	}

	y := 12
	parents := limit(nb.Parents, gMaxRow, func(r string) gNode { return node(r, "parent", nb.Category[r]) })
	y = rows(parents, y, 58)
	if len(parents) > 0 {
		y += 18
	}
	left := limit(nb.LinksTo, gMaxCol, func(r string) gNode {
		if nb.Mutual[r] {
			return node(r, "link mutual", "")
		}
		return node(r, "link", "")
	})
	right := limit(nb.LinkedFrom, gMaxCol, func(r string) gNode { return node(r, "back", "") })
	band := max(1, max(len(left), len(right))) * (gNodeH + 10)
	center := gNode{Rel: rel, Label: clip(s.noteTitle(rel), gChars), Class: "self", X: gW/2 - gNodeW/2, Y: y + band/2 - gNodeH/2}
	nodes = append(nodes, center)
	col := func(list []gNode, x int) {
		top := y + band/2 - (len(list)*(gNodeH+10)-10)/2
		for i := range list {
			list[i].X, list[i].Y = x, top+i*(gNodeH+10)
			nodes = append(nodes, list[i])
		}
	}
	col(left, 8)
	col(right, gW-8-gNodeW)
	y += band + 34
	children := limit(nb.Children, gMaxRow*2, func(r string) gNode { return node(r, "child", "") })
	y = rows(children, y, gNodeH+14)
	height := y + 4

	var b strings.Builder
	w := func(parts ...string) {
		for _, p := range parts {
			b.WriteString(p)
		}
	}
	w(`<svg class="graph" viewBox="0 0 `, itoa(gW), ` `, itoa(height), `" role="img" aria-label="Notes connected to this one">`)
	w(`<defs><marker id="gArrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" class="ga"/></marker></defs>`)
	// edges among the neighbours (faint), then to the note
	at := map[string]gNode{}
	for _, n := range nodes {
		if n.Rel != "" {
			at[n.Rel] = n
		}
	}
	snap := s.current()
	for _, a := range nodes {
		// parents (the Structure note) link to nearly everything: leave them out
		if a.Rel == "" || a.Rel == rel || a.Class == "parent" {
			continue
		}
		for _, l := range snap.forward[a.Rel] {
			if bn, ok := at[l.To]; ok && l.To != rel && l.To != a.Rel && bn.Class != "parent" {
				w(`<line class="ge faint" x1="`, itoa(a.cx()), `" y1="`, itoa(a.cy()), `" x2="`, itoa(bn.cx()), `" y2="`, itoa(bn.cy()), `"/>`)
			}
		}
	}
	for _, n := range nodes {
		if n.Class == "self" {
			continue
		}
		switch {
		case strings.HasPrefix(n.Class, "parent"):
			from := n.Y + gNodeH
			if n.Sub != "" {
				from += 17 // below its section label
			}
			w(curve(n.cx(), from, center.cx(), center.Y, "ge structure", ""))
		case strings.HasPrefix(n.Class, "child"):
			w(curve(center.cx(), center.Y+gNodeH, n.cx(), n.Y, "ge structure", ""))
		case strings.HasPrefix(n.Class, "link"):
			start := ""
			if strings.Contains(n.Class, "mutual") {
				start = ` marker-start="url(#gArrow)"`
			}
			w(`<line class="ge" x1="`, itoa(center.X), `" y1="`, itoa(center.cy()), `" x2="`, itoa(n.X+gNodeW), `" y2="`, itoa(n.cy()), `" marker-end="url(#gArrow)"`, start, `/>`)
		case strings.HasPrefix(n.Class, "back"):
			w(`<line class="ge" x1="`, itoa(n.X), `" y1="`, itoa(n.cy()), `" x2="`, itoa(center.X+gNodeW), `" y2="`, itoa(center.cy()), `" marker-end="url(#gArrow)"/>`)
		}
	}
	for _, n := range nodes {
		label := `<rect x="` + itoa(n.X) + `" y="` + itoa(n.Y) + `" width="` + itoa(gNodeW) + `" height="` + itoa(gNodeH) + `" rx="7"/>` +
			`<text x="` + itoa(n.cx()) + `" y="` + itoa(n.cy()+4) + `">` + esc(n.Label) + `</text>`
		if n.Sub != "" {
			label += `<text class="gsub" x="` + itoa(n.cx()) + `" y="` + itoa(n.Y+gNodeH+13) + `">` + esc(n.Sub) + `</text>`
		}
		if n.Rel == "" || n.Rel == rel {
			w(`<g class="gn `, n.Class, `">`, label, `</g>`)
			continue
		}
		title := s.noteTitle(n.Rel)
		if n.Sub != "" {
			title += " (" + n.Sub + ")"
		}
		w(`<a href="`, esc(s.noteURL(n.Rel, 0)), `"><g class="gn `, n.Class, `"><title>`, esc(title), `</title>`, label, `</g></a>`)
	}
	w(`</svg>`)
	return template.HTML(b.String())
}

// curve is a vertical S-curve from (x1,y1) down to (x2,y2).
func curve(x1, y1, x2, y2 int, class, extra string) string {
	mid := (y1 + y2) / 2
	return `<path class="` + class + `" d="M` + itoa(x1) + ` ` + itoa(y1) + `C` + itoa(x1) + ` ` + itoa(mid) + ` ` + itoa(x2) + ` ` + itoa(mid) + ` ` + itoa(x2) + ` ` + itoa(y2) + `"` + extra + `/>`
}

// ---------------------------------------------------------------------------
// The whole structure (/graph)
// ---------------------------------------------------------------------------

type treeNode struct {
	Rel      string // a note, or "" for a section of a structure
	Text     string
	Lnum     int // where its parent lists it
	Children []*treeNode
	Again    bool // already in the tree above: not expanded again
	Root     bool // a Structure note (else a hub the tree doesn't reach)
	level    int
	indent   int
}

// structureTree assembles the structure from the roots down, expanding
// every note that holds structure (once).
func (s *Server) structureTree() []*treeNode {
	info := s.current().structure
	seen := map[string]bool{}
	var roots []*treeNode
	var expand func(n *treeNode)
	expand = func(n *treeNode) {
		if seen[n.Rel] {
			n.Again = true
			return
		}
		seen[n.Rel] = true
		n.Children = append(n.Children, s.structureOf(n.Rel)...)
		var walk func(list []*treeNode)
		walk = func(list []*treeNode) {
			for _, c := range list {
				if c.Rel != "" {
					expand(c)
				} else {
					walk(c.Children)
				}
			}
		}
		walk(n.Children)
	}
	add := func(rel string, root bool) {
		if seen[rel] {
			return
		}
		n := &treeNode{Rel: rel, Text: s.noteTitle(rel), Root: root}
		expand(n)
		roots = append(roots, n)
	}
	for _, r := range info.Roots {
		add(r, true)
	}
	// hubs nothing in the tree reaches: their own trees, after
	for _, r := range info.Sources {
		add(r, false)
	}
	return roots
}

// structureOf is what rel's structure lines list: sections (headings, bold
// headings, labels) holding links to notes; a link indented under another
// is its child.
func (s *Server) structureOf(rel string) []*treeNode {
	snap := s.current()
	doc := s.ix.Doc(rel)
	ranges := snap.structure.Ranges[rel]
	if doc == nil || len(ranges) == 0 {
		return nil
	}
	byLine := map[int][]string{}
	for _, l := range snap.forward[rel] {
		byLine[l.Lnum] = append(byLine[l.Lnum], l.To)
	}
	top := &treeNode{level: -1}
	for _, rg := range ranges {
		sections := []*treeNode{top}
		var items []*treeNode // link lines, by indent
		for lnum := rg.First; lnum <= rg.Last; lnum++ {
			if n := doc.NodeStartingAt(lnum); n != nil && n.Type != "article" {
				if lnum == rg.First && n.Level == 1 && strings.EqualFold(strings.TrimSpace(n.Text), structureName) {
					continue // the # Structure heading itself
				}
				for len(sections) > 1 && sections[len(sections)-1].level >= n.Level {
					sections = sections[:len(sections)-1]
				}
				sec := &treeNode{Text: n.Text, Lnum: lnum, level: n.Level}
				parent := sections[len(sections)-1]
				parent.Children = append(parent.Children, sec)
				sections = append(sections, sec)
				items = items[:0]
			}
			targets := byLine[lnum]
			line := doc.Lines[lnum-1]
			it := syntax.ItemOf(line)
			if len(targets) == 0 && (it == nil || doc.NodeStartingAt(lnum) != nil) {
				continue
			}
			indent := len(line) - len(strings.TrimLeft(line, " \t"))
			for len(items) > 0 && items[len(items)-1].indent >= indent {
				items = items[:len(items)-1]
			}
			parent := sections[len(sections)-1]
			if len(items) > 0 {
				parent = items[len(items)-1]
			}
			if len(targets) == 0 {
				// a bullet without a link groups the bullets indented under it
				if text := strings.TrimSpace(line[it.ContentCol:]); text != "" {
					g := &treeNode{Text: text, Lnum: lnum, indent: indent}
					parent.Children = append(parent.Children, g)
					items = append(items, g)
				}
				continue
			}
			var first *treeNode
			for _, t := range targets {
				if t == parent.Rel {
					continue // [Me/#Contacts] under [Me]: the note itself
				}
				// listed again under the same parent: the same entry
				var c *treeNode
				for _, sib := range parent.Children {
					if sib.Rel == t {
						c = sib
						break
					}
				}
				if c == nil {
					c = &treeNode{Rel: t, Text: s.noteTitle(t), Lnum: lnum}
					parent.Children = append(parent.Children, c)
				}
				c.indent = indent
				if first == nil {
					first = c
				}
			}
			if first != nil {
				items = append(items, first)
			}
		}
	}
	return prune(top.Children)
}

// prune drops sections with no notes under them.
func prune(list []*treeNode) []*treeNode {
	var out []*treeNode
	for _, n := range list {
		n.Children = prune(n.Children)
		if n.Rel != "" || len(n.Children) > 0 {
			out = append(out, n)
		}
	}
	return out
}

// gtNote is a note in /graph: its link, with the notes it links with (for
// hover) and its header tags (for the tag filter) as data, and (count) how
// many notes those are.
func (s *Server) gtNote(rel, text string, count bool) string {
	snap := s.current()
	var rels []string
	for _, l := range snap.forward[rel] {
		rels = append(rels, l.To)
	}
	for _, bl := range snap.backlinks[rel] {
		if bl.FromNote {
			rels = append(rels, bl.From)
		}
	}
	sort.Strings(rels)
	rels = compactStrings(rels)
	var tags []string
	if d := s.ix.Doc(rel); d != nil {
		for _, t := range d.Header().Tags {
			tags = append(tags, strings.ToLower(t))
		}
	}
	a := `<a class="gt-note" href="` + esc(s.noteURL(rel, 0)) + `" data-rel="` + esc(rel) + `" data-links="` + esc(strings.Join(rels, "\n")) + `"`
	if len(tags) > 0 {
		a += ` data-tags="` + esc(strings.Join(tags, " ")) + `"`
	}
	a += `>` + esc(text) + `</a>`
	if count && len(rels) > 0 {
		a += ` <span class="gt-count dim" title="Notes it links to or that link to it">` + strconv.Itoa(len(rels)) + `</span>`
	}
	return a
}

// gtHeadingsMax: at most this many linked headings under a note in /graph.
const gtHeadingsMax = 6

// gtHeadings: the headings of a note that other notes link to, in note
// order, each with how many notes link to it: the structure the notes
// actually grow, under the note in /graph. "" for none.
func (s *Server) gtHeadings(rel string) string {
	snap := s.current()
	d := s.ix.Doc(rel)
	if d == nil {
		return ""
	}
	type head struct {
		n    int
		node string
		from map[string]bool
	}
	by := map[int]*head{}
	for _, bl := range snap.backlinks[rel] {
		if !bl.FromNote || bl.From == rel || bl.ToLnum < 1 {
			continue
		}
		// the innermost heading at or above the target line
		n := d.NodeAt(bl.ToLnum)
		for n != nil && !n.IsRoot() && n.Type != syntax.KindHeading {
			n = n.Parent
		}
		if n == nil || n.IsRoot() || n.Type != syntax.KindHeading {
			continue
		}
		h := by[n.Start]
		if h == nil {
			h = &head{n: n.Start, node: n.Text, from: map[string]bool{}}
			by[n.Start] = h
		}
		h.from[bl.From] = true
	}
	if len(by) == 0 {
		return ""
	}
	list := make([]*head, 0, len(by))
	for _, h := range by {
		list = append(list, h)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].n < list[j].n })
	var b strings.Builder
	b.WriteString(`<ul class="gt-heads" aria-label="Headings other notes link to">`)
	for i, h := range list {
		if i == gtHeadingsMax {
			b.WriteString(`<li class="dim">+` + strconv.Itoa(len(list)-i) + ` more</li>`)
			break
		}
		b.WriteString(`<li><a href="` + esc(s.noteURL(rel, h.n)) + `">` + esc(h.node) + `</a> <span class="dim" title="Notes linking to it">` + strconv.Itoa(len(h.from)) + `</span></li>`)
	}
	b.WriteString(`</ul>`)
	return b.String()
}

// openDepth: lists this deep in a card start open; deeper ones are closed,
// showing how many notes they hold.
const openDepth = 2

// graphHTML lays the tree out as cards: each Structure note's top-level
// sections and sub-trees, its loose notes together, and each hub the tree
// doesn't reach.
func (s *Server) graphHTML(roots []*treeNode) template.HTML {
	var b strings.Builder
	var write func(list []*treeNode, depth int)
	write = func(list []*treeNode, depth int) {
		b.WriteString(`<ul class="gt">`)
		for _, n := range list {
			open := ""
			if depth < openDepth {
				open = " open"
			}
			more := ""
			if depth >= openDepth {
				more = ` <span class="gt-more dim" title="Notes under it">+` + strconv.Itoa(countNotes(n.Children)) + `</span>`
			}
			if n.Rel == "" {
				b.WriteString(`<li class="gt-sec"><details` + open + `><summary>` + esc(n.Text) + more + `</summary>`)
				write(n.Children, depth+1)
				b.WriteString(`</details></li>`)
				continue
			}
			a := s.gtNote(n.Rel, n.Text, true)
			if n.Again {
				a += ` <span class="dim" title="Listed in another place too; its notes are shown there">(above)</span>`
			}
			heads := ""
			if !n.Again {
				heads = s.gtHeadings(n.Rel)
			}
			if len(n.Children) == 0 {
				b.WriteString(`<li>` + a + heads + `</li>`)
				continue
			}
			b.WriteString(`<li><details` + open + `><summary>` + a + more + `</summary>` + heads)
			write(n.Children, depth+1)
			b.WriteString(`</details></li>`)
		}
		b.WriteString(`</ul>`)
	}
	card := func(title string, list []*treeNode, heads string) {
		b.WriteString(`<section class="gt-card"><h2>` + title + ` <span class="gt-n dim" title="Notes in it">` + strconv.Itoa(countNotes(list)) + `</span></h2>` + heads)
		write(list, 0)
		b.WriteString(`</section>`)
	}
	b.WriteString(`<div class="gt-cols">`)
	for _, root := range roots {
		if !root.Root {
			card(s.gtNote(root.Rel, root.Text, false), root.Children, s.gtHeadings(root.Rel))
			continue
		}
		var loose []*treeNode
		for _, c := range root.Children {
			if c.Rel != "" && len(c.Children) == 0 {
				loose = append(loose, c)
			}
		}
		if len(loose) > 0 {
			card(s.gtNote(root.Rel, root.Text, false), loose, "")
		}
		for _, c := range root.Children {
			switch {
			case c.Rel == "":
				card(esc(c.Text), c.Children, "")
			case len(c.Children) > 0:
				card(s.gtNote(c.Rel, c.Text, false), c.Children, s.gtHeadings(c.Rel))
			}
		}
	}
	b.WriteString(`</div>`)
	return template.HTML(b.String())
}

// countNotes counts the notes in a tree.
func countNotes(list []*treeNode) int {
	n := 0
	for _, c := range list {
		if c.Rel != "" {
			n++
		}
		n += countNotes(c.Children)
	}
	return n
}

func compactStrings(list []string) []string {
	out := list[:0]
	for i, v := range list {
		if i == 0 || v != list[i-1] {
			out = append(out, v)
		}
	}
	return out
}

func (s *Server) handleGraph(w http.ResponseWriter, r *http.Request) {
	snap := s.current()
	info := snap.structure
	var unlinked []template.HTML
	for _, u := range info.Unlinked {
		unlinked = append(unlinked, template.HTML(s.gtNote(u, s.noteTitle(u), true)))
	}
	roots := s.structureTree()
	var main []template.HTML // the Structure notes, named in the intro
	for _, n := range roots {
		if n.Root {
			main = append(main, template.HTML(s.gtNote(n.Rel, n.Text, false)))
		}
	}
	s.render(w, r, "graph", http.StatusOK, map[string]any{
		"Title":    "Graph",
		"Tree":     s.graphHTML(roots),
		"Roots":    main,
		"HasTree":  len(info.Sources) > 0,
		"Unlinked": unlinked,
		"Linked":   info.Linked,
		"Total":    info.Total,
		"Tags":     snap.tags,
	})
}
