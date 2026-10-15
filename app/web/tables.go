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
// attribute the rows use, where it is, and the lines nested under it.

type tagRow struct {
	doc        *notes.Document
	lnum       int
	href       string // the line's first link
	linkText   string
	kind       string // web, pdf, book, image, video, audio, document, note, file
	tags       []string
	attrs      map[string]string
	nested     []int // lines indented under it (notes about it)
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
	var anyLink, anyTags, anyNested, anyTask bool
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
		anyNested = anyNested || len(row.nested) > 0
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
	if anyNested {
		th("Notes", "value")
	}
	w(`</tr></thead><tbody>`)

	for _, row := range rows {
		d := row.doc
		r := &noteRenderer{s: s, doc: d, slides: true} // slides: attributes hidden
		line := d.Lines[row.lnum-1]
		from := 0
		if it := syntax.ItemOf(line); it != nil {
			from = it.ContentCol
		} else {
			from = len(line) - len(strings.TrimLeft(line, " \t"))
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
		w(`<td class="tt-item">`, r.inline(line, d.Spans(row.lnum), from, len(line)), `</td>`)
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
		if n := d.NodeAt(row.lnum); n != nil && !n.IsRoot() {
			if bc := n.Breadcrumb(" › "); bc != "" {
				where = bc
			}
		}
		w(`<td class="tt-where"><a href="`, esc(s.noteURL(d.Rel, row.lnum)), `">`, esc(where), `</a></td>`)
		if anyNested {
			if len(row.nested) == 0 {
				w(`<td data-v="0"></td>`)
			} else {
				w(`<td data-v="`, itoa(len(row.nested)), `"><details><summary>`, itoa(len(row.nested)), `</summary><ul class="plain">`)
				for _, l := range row.nested {
					nl := d.Lines[l-1]
					nf := len(nl) - len(strings.TrimLeft(nl, " \t"))
					if it := syntax.ItemOf(nl); it != nil {
						nf = it.ContentCol
					}
					w(`<li>`, r.inline(nl, d.Spans(l), nf, len(nl)), `</li>`)
				}
				w(`</ul></details></td>`)
			}
		}
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
	indent := len(line) - len(strings.TrimLeft(line, " \t"))
	for l := lnum + 1; l <= len(d.Lines) && len(row.nested) < 50; l++ {
		nl := d.Lines[l-1]
		if strings.TrimSpace(nl) == "" {
			continue
		}
		if len(nl)-len(strings.TrimLeft(nl, " \t")) <= indent || d.NodeStartingAt(l) != nil {
			break
		}
		row.nested = append(row.nested, l)
	}
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
