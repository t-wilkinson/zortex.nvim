package web

import (
	"net/url"
	"path"
	"sort"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Tag tables: !@[scope/tags] shows the lines a tag search finds as a table
// in place, and the /link page of an @[...] search shows the same table.
// Every column is read off the lines: the item, the link it holds (and what
// kind of thing that is), its other tags, one column per @key(value)
// attribute the rows use, and where it is. Its notes (the lines nested
// under it, labels too, or a resource heading's section) show under the
// item: all of them up to shortNotes lines, else the first previewNotes and
// a button that opens them all in a panel, rendered like the note, with the
// first note they link to below them.

const (
	shortNotes   = 3
	previewNotes = 2
)

type tagRow struct {
	doc        *notes.Document
	lnum       int
	href       string // the line's first link
	linkText   string
	kind       string // web, pdf, book, image, video, audio, document, note, file
	tags       []string
	attrs      map[string]string
	nested     []int  // lines of its notes (not blank)
	notesTo    int    // the notes' last line (they start at lnum+1)
	notesBase  int    // their indent, shown as none
	notesRel   string // the first note they link to
	task, done bool
}

// tagTableHTML renders the tag search content (what is inside @[...]) as a
// table, resolved from the note from (nil: no local scope).
func (s *Server) tagTableHTML(from *notes.Document, content string) string {
	results, err := links.TagSearch(s.ix, content, links.Options{From: from})
	if err != nil || len(results) == 0 {
		msg := "No matches"
		if err != nil {
			msg = err.Error()
		}
		return `<p class="tt-empty dim">` + esc(msg) + `</p>`
	}
	query := map[string]bool{}
	for _, g := range links.ParseTagSearch(content).Groups {
		for _, t := range g {
			query[t] = true
		}
	}
	rows := make([]tagRow, 0, len(results))
	var attrKeys []string
	hasAttr := map[string]bool{}
	var anyLink, anyTags, anyTask bool
	kinds := map[string]bool{}
	tagCount := map[string]int{}
	for _, res := range results {
		row := s.tagRowOf(res.Doc, res.Lnum, query)
		for _, sp := range res.Doc.Spans(res.Lnum) {
			if sp.Type == "attribute" && sp.HasValue {
				k := syntax.Lower(sp.Key)
				if k == "id" {
					continue
				}
				if row.attrs == nil {
					row.attrs = map[string]string{}
				}
				row.attrs[k] = sp.Value
				if !hasAttr[k] {
					hasAttr[k] = true
					attrKeys = append(attrKeys, k)
				}
			}
		}
		anyLink = anyLink || row.href != ""
		anyTags = anyTags || len(row.tags) > 0
		anyTask = anyTask || row.task
		if row.kind != "" {
			kinds[row.kind] = true
		}
		for _, t := range row.tags {
			tagCount[t]++
		}
		rows = append(rows, row)
	}

	var b strings.Builder
	w := func(parts ...string) {
		for _, p := range parts {
			b.WriteString(p)
		}
	}
	w(`<div class="tag-table">`)
	w(`<div class="tt-tools"><input type="search" class="tt-filter" placeholder="Filter `, itoa(len(rows)), ` rows" aria-label="Filter rows">`)
	// one-click filters: the kinds of link, and tags some (not all) rows have
	var chips []string
	if len(kinds) > 1 {
		for k := range kinds {
			chips = append(chips, `<button type="button" class="tt-chip" data-kind="`+esc(k)+`">`+esc(k)+`</button>`)
		}
		sort.Strings(chips)
	}
	var tagChips []string
	for t, n := range tagCount {
		if n < len(rows) {
			tagChips = append(tagChips, t)
		}
	}
	sort.Strings(tagChips)
	for _, t := range tagChips {
		chips = append(chips, `<button type="button" class="tt-chip" data-tag="`+esc(t)+`">@`+esc(t)+`</button>`)
	}
	w(strings.Join(chips, ""), `<span class="tt-count dim" aria-live="polite"></span></div>`)

	w(`<div class="table-wrap"><table class="tt"><thead><tr>`)
	th := func(label, sortAs string) {
		w(`<th scope="col"><button type="button" class="tt-sort" data-sort="`, sortAs, `">`, label, `</button></th>`)
	}
	if anyTask {
		th(`<span class="dim">✓</span>`, "text")
	}
	th("Item", "text")
	if anyLink {
		th("Link", "text")
		if len(kinds) > 0 {
			th("Kind", "text")
		}
	}
	if anyTags {
		th("Tags", "text")
	}
	for _, k := range attrKeys {
		th("@"+esc(k), "value")
	}
	th("Where", "text")
	w(`</tr></thead><tbody>`)

	asts := map[*notes.Document]*syntax.AST{}
	for _, row := range rows {
		d := row.doc
		r := &noteRenderer{s: s, doc: d, slides: true} // slides: attributes hidden
		line := d.Lines[row.lnum-1]
		from, to := 0, len(line)
		if it := syntax.ItemOf(line); it != nil {
			from = it.ContentCol
		} else if c := syntax.Classify(line); c.Kind == syntax.KindHeading && c.ContentCol != nil {
			from = *c.ContentCol
			if c.ContentEnd != nil {
				to = *c.ContentEnd
			}
		} else {
			from = len(line) - len(strings.TrimLeft(line, " \t"))
		}
		notesHTML, previewHTML := "", ""
		if n := len(row.nested); n > 0 {
			if asts[d] == nil {
				asts[d] = d.Parse()
			}
			notesHTML = s.notesHTML(d, asts[d], row.lnum+1, row.notesTo, row.notesBase)
			previewHTML = notesHTML
			if n > shortNotes {
				previewHTML = s.notesHTML(d, asts[d], row.lnum+1, row.nested[previewNotes-1], row.notesBase)
			}
		}
		w(`<tr data-kind="`, esc(row.kind), `" data-tags="`, esc(strings.Join(row.tags, " ")), `">`)
		if anyTask {
			switch {
			case row.done:
				w(`<td data-v="1"><span class="box done" role="img" aria-label="done"></span></td>`)
			case row.task:
				w(`<td data-v="0"><span class="box open" role="img" aria-label="open task"></span></td>`)
			default:
				w(`<td></td>`)
			}
		}
		w(`<td class="tt-item">`, r.inline(line, d.Spans(row.lnum), from, to))
		if previewHTML != "" {
			w(`<div class="tt-notes">`, previewHTML, `</div>`)
		}
		if n := len(row.nested); n > shortNotes {
			// the panel (tables.js): the notes, then the note they link to
			title := plainText(line, d.Spans(row.lnum), from, to)
			w(`<div class="tt-more"><button type="button" class="tt-notes-btn" aria-haspopup="dialog" data-title="`, esc(title), `"`)
			if row.notesRel != "" {
				title := row.notesRel
				if nd := s.ix.Doc(row.notesRel); nd != nil {
					title = nd.Title()
				}
				w(` data-note="`, esc(row.notesRel), `" data-note-href="`, esc(s.noteURL(row.notesRel, 0)), `" data-note-title="`, esc(title), `"`)
			}
			w(`>All notes <span class="dim">`, itoa(n), `</span></button><template>`, notesHTML, `</template></div>`)
		}
		w(`</td>`)
		if anyLink {
			w(`<td class="tt-link">`)
			if row.href != "" {
				w(`<a href="`, esc(row.href), `"`, externalAttrs(row.href), `>`, esc(row.linkText), `</a>`)
			}
			w(`</td>`)
			if len(kinds) > 0 {
				w(`<td class="tt-kind">`, esc(row.kind), `</td>`)
			}
		}
		if anyTags {
			w(`<td class="tt-tags">`)
			for _, t := range row.tags {
				w(`<span class="tag">@`, esc(t), `</span> `)
			}
			w(`</td>`)
		}
		for _, k := range attrKeys {
			v, ok := row.attrs[k]
			if ok {
				w(`<td data-v="`, esc(v), `">`, esc(v), `</td>`)
			} else {
				w(`<td></td>`)
			}
		}
		where := d.Title()
		n := d.NodeAt(row.lnum)
		if n != nil && n.Start == row.lnum && links.IsResourceHeading(d, row.lnum) {
			n = n.Parent // a resource heading is where it is, not its own section
		}
		if n != nil && !n.IsRoot() {
			if bc := n.Breadcrumb(" › "); bc != "" {
				where = bc
			}
		}
		w(`<td class="tt-where"><a href="`, esc(s.noteURL(d.Rel, row.lnum)), `">`, esc(where), `</a></td>`)
		w(`</tr>`)
	}
	w(`</tbody></table></div></div>`)
	return b.String()
}

// tagRowOf reads one found line: its link, tags (minus the searched ones)
// and the lines nested under it.
func (s *Server) tagRowOf(d *notes.Document, lnum int, query map[string]bool) tagRow {
	row := tagRow{doc: d, lnum: lnum}
	line := d.Lines[lnum-1]
	if it := syntax.ItemOf(line); it != nil && it.Mark != "" {
		row.task = true
		row.done = it.Mark == "x" || it.Mark == "X"
	}
	for _, t := range links.TagsAt(d, lnum) {
		if !query[t] {
			row.tags = append(row.tags, t)
		}
	}
	syntax.Walk(d.Spans(lnum), func(sp *syntax.Span) {
		if row.href != "" {
			return
		}
		switch sp.Type {
		case "markdown":
			if href, ok := s.pathHref(d, sp.URL); ok {
				row.href, row.linkText, row.kind = href, shortTarget(sp.URL), kindOf(s, sp.URL)
			}
		case "url":
			row.href, row.linkText, row.kind = sp.URL, shortTarget(sp.URL), kindOf(s, sp.URL)
		case "filepath":
			p := strings.TrimRight(sp.Path, ".,;:!?")
			if href, ok := s.pathHref(d, p); ok {
				row.href, row.linkText, row.kind = href, path.Base(p), kindOf(s, p)
			}
		case "link", "live_link":
			if s.fileLike(sp.Definition) {
				if href, ok := s.pathHref(d, sp.Definition); ok {
					row.href, row.linkText, row.kind = href, path.Base(sp.Definition), kindOf(s, sp.Definition)
				}
				return
			}
			res, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: d, Lnum: lnum})
			if err != nil || res == nil {
				return
			}
			if res.Link != nil {
				if href, ok := s.followHref(*res, 1); ok {
					t := links.SpanText(res.Link)
					row.href, row.linkText, row.kind = href, shortTarget(t), kindOf(s, t)
				}
				return
			}
			row.href, row.linkText, row.kind = s.noteURL(res.Doc.Rel, res.Lnum), sp.Definition, "note"
		}
	})
	// its notes: a resource heading's section, or the lines indented under
	// it (labels among them stay its notes)
	if n := d.NodeStartingAt(lnum); n != nil && links.IsResourceHeading(d, lnum) {
		for l := lnum + 1; l <= n.End && len(row.nested) < 200; l++ {
			if strings.TrimSpace(d.Lines[l-1]) != "" {
				row.nested = append(row.nested, l)
				row.notesTo = l
			}
		}
	} else {
		indent := len(line) - len(strings.TrimLeft(line, " \t"))
		row.notesBase = -1
		for l := lnum + 1; l <= len(d.Lines) && len(row.nested) < 200; l++ {
			nl := d.Lines[l-1]
			if strings.TrimSpace(nl) == "" {
				continue
			}
			ind := len(nl) - len(strings.TrimLeft(nl, " \t"))
			if ind <= indent {
				break
			}
			if n := d.NodeStartingAt(l); n != nil && n.Type != syntax.KindLabel {
				break
			}
			row.nested = append(row.nested, l)
			row.notesTo = l
			if row.notesBase < 0 || ind < row.notesBase {
				row.notesBase = ind
			}
		}
		if row.notesBase < 0 {
			row.notesBase = 0
		}
	}
	row.notesRel = s.linkedNote(d, row.nested)
	return row
}

// kindOf says what a link points to: a web page, a note, or a resource kind.
func kindOf(s *Server, target string) string {
	p := target
	if u, err := url.Parse(target); err == nil && (u.Scheme == "http" || u.Scheme == "https") {
		ext := extOf(u.Path)
		if ext != "" && s.resExts[ext] {
			return resourceKind(ext)
		}
		return "web"
	}
	ext := extOf(p)
	switch {
	case ext == "":
		return "file"
	case "."+ext == s.cfg.Ext:
		return "note"
	case s.resExts[ext]:
		return resourceKind(ext)
	}
	return "file"
}

// shortTarget is a link target to show in a cell: a URL's host and path
// start, a path's file name.
func shortTarget(target string) string {
	if u, err := url.Parse(target); err == nil && u.Host != "" {
		host := strings.TrimPrefix(u.Host, "www.")
		p := strings.Trim(u.Path, "/")
		if p == "" {
			return host
		}
		if len(p) > 24 {
			p = p[:24] + "…"
		}
		return host + "/" + p
	}
	return path.Base(target)
}

// plainText is line[from:to] as text: links by their text, no attributes.
func plainText(line string, spans []syntax.Span, from, to int) string {
	var b strings.Builder
	pos := from
	for i := range spans {
		sp := &spans[i]
		if sp.S < pos || sp.E > to {
			continue
		}
		b.WriteString(line[pos:sp.S])
		switch sp.Type {
		case "attribute", "hidden":
		case "bold", "italic":
			b.WriteString(plainText(line, sp.Children, sp.InnerS, sp.InnerE))
		case "code", "math":
			b.WriteString(line[sp.InnerS:sp.InnerE])
		default:
			if t := links.SpanText(sp); t != "" {
				b.WriteString(t)
			} else {
				b.WriteString(line[sp.S:sp.E])
			}
		}
		pos = sp.E
	}
	if pos < to {
		b.WriteString(line[pos:to])
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// notesHTML renders a row's notes (lines first..last) like the note, with
// their indent from base shown as none and without the note's line ids
// (the page may hold the note too).
func (s *Server) notesHTML(d *notes.Document, ast *syntax.AST, first, last, base int) string {
	r := &noteRenderer{s: s, doc: d, ast: ast, dedent: base}
	r.renderRange(first, last)
	return strings.ReplaceAll(r.b.String(), ` id="`, ` data-id="`)
}

// linkedNote is the first note the lines link to as a whole ([Rust book],
// [z/rust-book.zortex](…)), or "".
func (s *Server) linkedNote(d *notes.Document, lines []int) string {
	for _, l := range lines {
		rel := ""
		syntax.Walk(d.Spans(l), func(sp *syntax.Span) {
			if rel != "" {
				return
			}
			switch sp.Type {
			case "link", "live_link":
				if s.fileLike(sp.Definition) {
					if r, _, local, dir, ok := s.resolveFile(d, sp.Definition); ok && local && !dir && s.isNote(r) {
						rel = r
					}
					return
				}
				res, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: d, Lnum: l})
				if err == nil && res != nil && res.Whole && res.Doc != d {
					rel = res.Doc.Rel
				}
			case "markdown", "filepath":
				p := sp.URL
				if sp.Type == "filepath" {
					p = strings.TrimRight(sp.Path, ".,;:!?")
				}
				if r, _, local, dir, ok := s.resolveFile(d, p); ok && local && !dir && s.isNote(r) {
					rel = r
				}
			}
		})
		if rel != "" {
			return rel
		}
	}
	return ""
}
