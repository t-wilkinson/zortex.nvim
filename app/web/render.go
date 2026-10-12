package web

import (
	"html/template"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// A note renders line by line: every line is an element with id "L<lnum>",
// so links to a line (and to a section, which is its first line) land on it.
// Code, math and table blocks render as one element whose rows carry the ids.
// Links are resolved while rendering with the same rules as the plugin.

var esc = template.HTMLEscapeString

func itoa(n int) string { return strconv.Itoa(n) }

// escapePath escapes each segment of a rel path for a URL.
func escapePath(rel string) string {
	parts := strings.Split(rel, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

type noteRenderer struct {
	s   *Server
	doc *notes.Document
	ast *syntax.AST
	b   strings.Builder
}

// renderNote is the HTML body of a note (without its header block, which
// the template shows from the document's names and tags).
func (s *Server) renderNote(doc *notes.Document) template.HTML {
	r := &noteRenderer{s: s, doc: doc, ast: doc.Parse()}
	r.render()
	return template.HTML(r.b.String())
}

func (r *noteRenderer) w(parts ...string) {
	for _, p := range parts {
		r.b.WriteString(p)
	}
}

func (r *noteRenderer) render() {
	lines, ast := r.doc.Lines, r.ast
	for i := 0; i < len(lines); i++ {
		lnum := i + 1
		d := ast.Lines[i]
		if lnum <= ast.Header.LastLnum {
			r.w(`<span class="anchor" id="L`, itoa(lnum), `"></span>`)
			continue
		}
		switch d.Kind {
		case syntax.KindFence:
			i = r.block(i, "code", syntax.KindFence)
		case syntax.KindMathFence:
			i = r.block(i, "math", syntax.KindMathFence)
		case syntax.KindTable:
			i = r.table(i)
		default:
			r.line(lnum, d)
		}
	}
}

// block renders a fenced code or math block starting at line index i and
// returns the index of its last line.
func (r *noteRenderer) block(i int, kind, fence string) int {
	lines, ast := r.doc.Lines, r.ast
	lang := ""
	if l := ast.Lines[i].Lang; l != nil {
		lang = *l
	}
	cls := "code"
	if kind == "math" {
		cls = "math-block"
	}
	r.w(`<pre class="`, cls, `" id="L`, itoa(i+1), `"`)
	if lang != "" {
		r.w(` data-lang="`, esc(lang), `"`)
	}
	r.w(`><code>`)
	j := i + 1
	for ; j < len(lines); j++ {
		d := ast.Lines[j]
		if d.Kind == fence && d.Close {
			break
		}
		r.w(`<span class="cl" id="L`, itoa(j+1), `">`, esc(lines[j]), "\n</span>")
	}
	r.w(`</code></pre>`)
	if j < len(lines) {
		r.w(`<span class="anchor" id="L`, itoa(j+1), `"></span>`)
		return j
	}
	return j - 1
}

// table renders consecutive table lines from index i; a row followed by a
// separator row (|---|) is the header.
func (r *noteRenderer) table(i int) int {
	lines, ast := r.doc.Lines, r.ast
	j := i
	for j+1 < len(lines) && ast.Lines[j+1].Kind == syntax.KindTable {
		j++
	}
	r.w(`<div class="table-wrap"><table>`)
	for k := i; k <= j; k++ {
		d := ast.Lines[k]
		if d.Separator != nil && *d.Separator {
			r.w(`<tr class="sep" id="L`, itoa(k+1), `"></tr>`)
			continue
		}
		cell := "td"
		if k < j && ast.Lines[k+1].Separator != nil && *ast.Lines[k+1].Separator {
			cell = "th"
		}
		r.w(`<tr id="L`, itoa(k+1), `">`)
		for _, c := range tableCells(lines[k]) {
			r.w("<", cell, ">", r.inline(c, syntax.Inline(c, 0, len(c)), 0, len(c)), "</", cell, ">")
		}
		r.w(`</tr>`)
	}
	r.w(`</table></div>`)
	return j
}

func tableCells(line string) []string {
	t := strings.TrimSpace(line)
	t = strings.TrimPrefix(t, "|")
	t = strings.TrimSuffix(t, "|")
	cells := strings.Split(t, "|")
	for i, c := range cells {
		cells[i] = strings.TrimSpace(c)
	}
	return cells
}

func (r *noteRenderer) line(lnum int, d *syntax.Line) {
	line := r.doc.Lines[lnum-1]
	id := itoa(lnum)
	spans := r.doc.Spans(lnum)
	from, to := 0, len(line)
	if d.ContentCol != nil {
		from = *d.ContentCol
	}
	if d.ContentEnd != nil {
		to = *d.ContentEnd
	}
	content := func() string { return r.inline(line, spans, from, to) }
	indent := ""
	if d.Indent > 0 {
		indent = ` style="--ind:` + itoa(d.Indent) + `"`
	}

	switch d.Kind {
	case syntax.KindBlank:
		r.w(`<div class="ln blank" id="L`, id, `"></div>`)
	case syntax.KindHeading:
		h := itoa(d.Heading)
		if d.Heading > 6 {
			h = "6"
		}
		r.w(`<h`, h, ` class="ln" id="L`, id, `">`, content(), `<a class="pin" href="#L`, id, `" aria-label="Link to this section">#</a></h`, h, `>`)
	case syntax.KindBoldHeading:
		r.w(`<div class="ln bold-heading" id="L`, id, `">`, content(), `</div>`)
	case syntax.KindLabel:
		r.w(`<div class="ln label" id="L`, id, `"`, indent, `>`)
		if d.Item != nil {
			r.marker(line, d.Item)
		}
		r.w(content(), `</div>`)
	case syntax.KindItem:
		cls := "ln item"
		if d.Item.Mark != "" {
			cls += " task"
			if d.Item.Mark == "x" || d.Item.Mark == "X" {
				cls += " done"
			}
		}
		r.w(`<div class="`, cls, `" id="L`, id, `"`, indent, `>`)
		r.marker(line, d.Item)
		r.w(`<span class="body">`, content(), `</span></div>`)
	case syntax.KindQuote:
		r.w(`<blockquote class="ln" id="L`, id, `"`, indent, `>`, content(), `</blockquote>`)
	case syntax.KindFootnote:
		r.w(`<div class="ln footnote" id="L`, id, `"><span class="fn-id" id="fn-`, esc(d.ID), `">`, esc(d.ID), `</span> `, content(), `</div>`)
	case syntax.KindTag:
		r.w(`<div class="ln tagline" id="L`, id, `">`, esc(line), `</div>`)
	default:
		r.w(`<div class="ln text" id="L`, id, `"`, indent, `>`)
		if d.Key != "" && d.KeyCol != nil && (len(spans) == 0 || spans[0].S >= *d.KeyCol+d.KeyLen) {
			k0, k1 := *d.KeyCol, *d.KeyCol+d.KeyLen
			r.w(r.inline(line, nil, from, k0), `<span class="key">`, esc(line[k0:k1]), `</span>`, r.inline(line, spans, k1, to))
		} else {
			r.w(content())
		}
		r.w(`</div>`)
	}
}

// marker renders a list item's marker, key and checkbox.
func (r *noteRenderer) marker(line string, it *syntax.Item) {
	switch it.MarkerType {
	case "time":
		r.w(`<span class="marker time">`, esc(it.Marker), `</span>`)
	case "ordered":
		r.w(`<span class="marker ordered">`, esc(it.Marker), `</span>`)
	default:
		r.w(`<span class="marker bullet" aria-hidden="true"></span>`)
	}
	if it.Key != "" {
		r.w(`<span class="key">`, esc(it.Key), `:</span>`)
	}
	if it.Mark != "" {
		state, label := "open", "open task"
		if it.Mark == "x" || it.Mark == "X" {
			state, label = "done", "done"
		} else if it.Mark != " " {
			state, label = "other", it.Mark
		}
		r.w(`<span class="box `, state, `" role="img" aria-label="`, esc(label), `">`)
		if state == "other" {
			r.w(esc(it.Mark))
		}
		r.w(`</span>`)
	}
}

// inline renders line[from:to] with its spans (sorted, non-overlapping).
func (r *noteRenderer) inline(line string, spans []syntax.Span, from, to int) string {
	var b strings.Builder
	pos := from
	for i := range spans {
		sp := &spans[i]
		if sp.S < pos || sp.E > to {
			continue
		}
		b.WriteString(esc(line[pos:sp.S]))
		b.WriteString(r.span(line, sp))
		pos = sp.E
	}
	if pos < to {
		b.WriteString(esc(line[pos:to]))
	}
	return b.String()
}

func (r *noteRenderer) span(line string, sp *syntax.Span) string {
	raw := line[sp.S:sp.E]
	switch sp.Type {
	case "link", "live_link":
		return r.s.linkHTML(r.doc, sp.Definition)
	case "markdown":
		href, ok := r.s.pathHref(r.doc, sp.URL)
		cls := "md"
		if !ok {
			cls += " broken"
		}
		return `<a class="` + cls + `" href="` + esc(href) + `"` + externalAttrs(href) + `>` + esc(sp.Text) + `</a>`
	case "url":
		return `<a class="url" href="` + esc(sp.URL) + `"` + externalAttrs(sp.URL) + `>` + esc(sp.URL) + `</a>`
	case "filepath":
		// sentence punctuation after a path isn't part of it: "see ./a.pdf, then"
		p := strings.TrimRight(sp.Path, ".,;:!?")
		tail := raw[len(raw)-(len(sp.Path)-len(p)):]
		if href, ok := r.s.pathHref(r.doc, p); ok {
			return `<a class="file" href="` + esc(href) + `">` + esc(raw[:len(raw)-len(tail)]) + `</a>` + esc(tail)
		}
		return `<code class="path">` + esc(raw) + `</code>`
	case "footnote_ref":
		return `<sup class="fnref"><a href="#fn-` + esc(sp.ID) + `">` + esc(sp.ID) + `</a></sup>`
	case "tag_search":
		terms := make([]string, len(sp.Terms))
		for i, t := range sp.Terms {
			terms[i] = "@" + strings.ReplaceAll(t, " ", `\ `)
		}
		return `<a class="tagsearch" href="` + esc(r.s.url("/search?q="+url.QueryEscape(strings.Join(terms, " ")))) + `">` + esc(raw) + `</a>`
	case "attribute":
		return `<span class="attr">` + esc(raw) + `</span>`
	case "code":
		return `<code>` + esc(line[sp.InnerS:sp.InnerE]) + `</code>`
	case "math":
		cls := "math"
		if sp.Display {
			cls += " display"
		}
		return `<span class="` + cls + `">` + esc(line[sp.InnerS:sp.InnerE]) + `</span>`
	case "bold":
		return `<strong>` + r.inline(line, sp.Children, sp.InnerS, sp.InnerE) + `</strong>`
	case "italic":
		return `<em>` + r.inline(line, sp.Children, sp.InnerS, sp.InnerE) + `</em>`
	case "time":
		return `<span class="time">` + esc(raw) + `</span>`
	}
	return esc(raw)
}

func externalAttrs(href string) string {
	if strings.HasPrefix(href, "http://") || strings.HasPrefix(href, "https://") {
		return ` target="_blank" rel="noopener noreferrer"`
	}
	return ""
}

// linkHTML renders a zortex link, resolved from `from`: it points at the
// canonical target (the first result, as following the link in Neovim does).
func (s *Server) linkHTML(from *notes.Document, def string) string {
	text := esc(def)
	if s.fileLike(def) {
		if href, ok := s.pathHref(from, def); ok {
			return `<a class="zl file" href="` + esc(href) + `">` + text + `</a>`
		}
		return `<a class="zl broken" title="File not found">` + text + `</a>`
	}
	results, err := links.Resolve(s.ix, "["+def+"]", links.Options{From: from})
	if err != nil || len(results) == 0 {
		msg := "No match"
		if err != nil {
			msg = err.Error()
		}
		return `<a class="zl broken" href="` + esc(s.linkURL(def, from.Rel)) + `" title="` + esc(msg) + `">` + text + `</a>`
	}
	first := results[0]
	title := first.Doc.Title()
	if first.Lnum > 1 {
		if n := first.Doc.NodeAt(first.Lnum); n != nil && !n.IsRoot() {
			title = n.Breadcrumb(" › ")
		}
	}
	cls := "zl"
	if len(results) > 1 {
		cls += " multi"
		title += " (+" + itoa(len(results)-1) + " more)"
	}
	return `<a class="` + cls + `" href="` + esc(s.noteURL(first.Doc.Rel, first.Lnum)) + `" title="` + esc(title) + `">` + text + `</a>`
}

// linkURL is the /link page for a definition (lists every target).
func (s *Server) linkURL(def, from string) string {
	q := url.Values{"to": {def}}
	if from != "" {
		q.Set("from", from)
	}
	return s.url("/link?" + q.Encode())
}

// pathHref resolves a path written in a note ("./scan.pdf", "z/img.png",
// "../other.zortex", "tt.pdf") to a viewer URL, with localRef's rules.
// External URLs pass through. ok is false when the file doesn't exist.
func (s *Server) pathHref(from *notes.Document, p string) (string, bool) {
	var names map[string][]string
	if snap := s.current(); snap != nil {
		names = snap.names
	}
	rel, frag, local, found := s.localRef(from.Rel, p, false, names)
	if !local {
		if p == "" || strings.HasPrefix(p, "~") {
			return "", false
		}
		return p, true
	}
	if !found {
		return "", false
	}
	st, err := os.Stat(s.ix.Path(rel))
	if err != nil {
		return "", false
	}
	if !st.IsDir() && s.isNote(rel) {
		return s.noteURL(rel, 0) + frag, true
	}
	return s.fileURL(rel) + frag, true
}

// tocEntry is a section in a note's outline.
type tocEntry struct {
	Text  string
	Lnum  int
	Depth int
}

// toc lists headings and bold headings (labels are too many to be useful).
func toc(doc *notes.Document) []tocEntry {
	var out []tocEntry
	var walk func(n *notes.Node, depth int)
	walk = func(n *notes.Node, depth int) {
		for _, c := range n.Children {
			switch c.Type {
			case syntax.KindHeading, syntax.KindBoldHeading:
				out = append(out, tocEntry{Text: c.Text, Lnum: c.Start, Depth: depth})
				walk(c, depth+1)
			case syntax.KindArticle:
				walk(c, depth)
			}
		}
	}
	walk(doc.Tree, 0)
	return out
}

// highlight escapes text and marks every occurrence of the words (ASCII
// case-insensitive, as search matches).
func highlight(text string, words []string) template.HTML {
	lower := syntax.Lower(text)
	marks := make([]bool, len(text)+1)
	any := false
	for _, w := range words {
		if w == "" {
			continue
		}
		for i := 0; ; {
			k := strings.Index(lower[i:], w)
			if k < 0 {
				break
			}
			for j := i + k; j < i+k+len(w); j++ {
				marks[j] = true
			}
			any = true
			i += k + len(w)
		}
	}
	if !any {
		return template.HTML(esc(text))
	}
	var b strings.Builder
	in := false
	start := 0
	for i := 0; i <= len(text); i++ {
		m := i < len(text) && marks[i]
		if m != in {
			if in {
				b.WriteString("<mark>" + esc(text[start:i]) + "</mark>")
			} else {
				b.WriteString(esc(text[start:i]))
			}
			start, in = i, m
		}
	}
	if start < len(text) {
		if in {
			b.WriteString("<mark>" + esc(text[start:]) + "</mark>")
		} else {
			b.WriteString(esc(text[start:]))
		}
	}
	return template.HTML(b.String())
}
