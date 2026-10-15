package web

import (
	"html/template"
	"net/url"
	"os"
	"path"
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

	slides bool        // a slide deck: attributes are hidden
	steps  map[int]int // slides: lnum -> the reveal step it appears in

	lnum   int    // the line being rendered (parent-relative links)
	md     *mdDoc // a Markdown file (markdown.go)
	inPara bool   // Markdown: inside a <p> of text lines
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

func (r *noteRenderer) render() { r.renderRange(1, len(r.doc.Lines)) }

// renderRange renders lines first..last (1-based, inclusive). A code, math
// or table block that starts in the range is rendered whole.
func (r *noteRenderer) renderRange(first, last int) {
	ast := r.ast
	for i := first - 1; i < last; i++ {
		lnum := i + 1
		d := ast.Lines[i]
		if lnum <= ast.Header.LastLnum {
			r.w(`<span class="anchor" id="L`, itoa(lnum), `"></span>`)
			continue
		}
		if r.md != nil {
			if j := r.mdBlock(i); j >= 0 {
				i = j
				continue
			}
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
	if r.md != nil {
		r.mdEndPara()
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
		r.w(`<tr id="L`, itoa(k+1), `"`)
		if n := r.steps[k+1]; n > 0 {
			r.w(` data-step="`, itoa(n), `"`)
		}
		r.w(`>`)
		for _, c := range tableCells(lines[k]) {
			spans := syntax.Inline(c, 0, len(c))
			if r.md != nil {
				spans = r.mdSpans(c, 0, len(c))
			}
			r.w("<", cell, ">", r.inline(c, spans, 0, len(c)), "</", cell, ">")
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
	r.lnum = lnum
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
	if r.md != nil {
		// Markdown: a "- Label:" item is an item, "Key:" is text
		if d.Item != nil && d.Kind != syntax.KindItem {
			d = &syntax.Line{Kind: syntax.KindItem, Indent: d.Indent, Item: d.Item}
			from, to = d.Item.ContentCol, len(line)
		}
		spans = r.mdSpans(line, from, to)
	}
	content := func() string { return r.inline(line, spans, from, to) }
	if sp := embedOnly(line, spans); sp != nil {
		r.w(`<div class="ln embed-table" id="L`, id, `">`, r.s.tagTableHTML(r.doc, sp.Content), `</div>`)
		return
	}
	indent := ""
	if d.Indent > 0 {
		indent = ` style="--ind:` + itoa(d.Indent) + `"`
	}
	if n := r.steps[lnum]; n > 0 {
		indent += ` data-step="` + itoa(n) + `"`
	}

	switch d.Kind {
	case syntax.KindBlank:
		r.w(`<div class="ln blank" id="L`, id, `"></div>`)
	case syntax.KindHeading:
		h := itoa(d.Heading)
		if d.Heading > 6 {
			h = "6"
		}
		pin := "L" + id
		r.w(`<h`, h, ` class="ln" id="L`, id, `">`)
		if r.md != nil {
			pin = r.md.slug(headingText(line, spans, from, to))
			r.w(`<span class="anchor" id="`, esc(pin), `"></span>`)
		}
		r.w(content(), `<a class="pin" href="#`, esc(pin), `" aria-label="Link to this section">#</a></h`, h, `>`)
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
		if r.md == nil && d.Key != "" && d.KeyCol != nil && (len(spans) == 0 || spans[0].S >= *d.KeyCol+d.KeyLen) {
			k0, k1 := *d.KeyCol, *d.KeyCol+d.KeyLen
			r.w(r.inline(line, nil, from, k0), `<span class="key">`, esc(line[k0:k1]), `</span>`, r.inline(line, spans, k1, to))
		} else {
			r.w(content())
		}
		r.w(`</div>`)
	}
}

// embedOnly is the !@[...] span of a line that holds nothing else.
func embedOnly(line string, spans []syntax.Span) *syntax.Span {
	if len(spans) != 1 || spans[0].Type != "tag_search" || !spans[0].Embed {
		return nil
	}
	if strings.TrimSpace(line[:spans[0].S]) != "" || strings.TrimSpace(line[spans[0].E:]) != "" {
		return nil
	}
	return &spans[0]
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
	if it.Key != "" && r.md == nil {
		r.w(`<span class="key">`, esc(it.Key), `:</span>`)
	}
	if it.Mark != "" {
		state, label := "open", "open task"
		title := ""
		if it.Mark == "x" || it.Mark == "X" {
			state, label = "done", "done"
		} else if it.Mark == ">" {
			state, label = "other moved", "carried to a later day"
			title = ` title="carried to a later day"`
		} else if it.Mark != " " {
			state, label = "other", it.Mark
		} else if r.md == nil && r.s.doneOnCalendar(r.doc, line) {
			// a calendar copy (same @id) is checked: done (mirrors.go)
			state, label = "done mirrored", "done on the calendar"
			title = ` title="done on the calendar"`
		}
		r.w(`<span class="box `, state, `" role="img" aria-label="`, esc(label), `"`, title, `>`)
		if strings.HasPrefix(state, "other") {
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
	case "live_link":
		if k := resourceKind(extOf(sp.Definition)); (k == "image" || k == "video") && r.s.fileLike(sp.Definition) {
			return r.s.imageHTML(r.doc, sp.Definition)
		}
		return r.linkHTML(sp.Definition)
	case "link":
		return r.linkHTML(sp.Definition)
	case "markdown":
		href, ok := r.s.pathHref(r.doc, sp.URL)
		cls := "md"
		if !ok {
			cls += " broken"
		}
		title := ""
		if sp.Value != "" && r.md != nil {
			title = ` title="` + esc(sp.Value) + `"`
		}
		return `<a class="` + cls + `" href="` + esc(href) + `"` + title + externalAttrs(href) + `>` + r.mdText(sp.Text) + `</a>`
	case "md_image":
		return r.mdImage(sp)
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
		// the tagged lines it finds (links.TagSearch), listed on the link page
		return `<a class="tagsearch" href="` + esc(r.s.linkURL("@["+sp.Content+"]", r.doc.Rel)) + `" title="` + esc(raw) + `">` + tagSearchText(sp.Content) + `</a>`
	case "attribute":
		if r.slides {
			return ""
		}
		return `<span class="attr">` + esc(raw) + `</span>`
	case "hidden":
		return ""
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

// tagSearchText shows a tag search like a link: a dim "@", no brackets, and
// its alternatives spaced ("rl,ai-model" -> "rl, ai-model").
func tagSearchText(content string) string {
	alts := strings.Split(content, ",")
	for i, a := range alts {
		alts[i] = strings.Join(strings.Fields(a), " ")
	}
	return `<span class="ts-at" aria-hidden="true">@</span>` + esc(strings.Join(alts, ", "))
}

func externalAttrs(href string) string {
	if strings.HasPrefix(href, "http://") || strings.HasPrefix(href, "https://") {
		return ` target="_blank" rel="noopener noreferrer"`
	}
	return ""
}

// linkHTML renders a link written on the line being rendered: a
// parent-relative one ([./-Item]) through its parent line's link, shown by
// its text ("Item").
func (r *noteRenderer) linkHTML(def string) string {
	if links.IsParentRelative(def) {
		text := strings.TrimSpace(syntax.Trim(def)[3:])
		abs, err := links.Absolute(r.doc.Lines, r.lnum, def)
		if err != nil {
			return `<a class="zl broken" title="` + esc(err.Error()) + `">` + esc(def) + `</a>`
		}
		return r.s.linkHTMLAs(r.doc, abs, text)
	}
	return r.s.linkHTML(r.doc, def)
}

// linkHTML renders a zortex link, resolved from `from`: it points at the
// canonical target (the first result, as following the link in Neovim does).
func (s *Server) linkHTML(from *notes.Document, def string) string {
	return s.linkHTMLAs(from, def, def)
}

// linkHTMLAs is linkHTML for `def` shown as `written`.
func (s *Server) linkHTMLAs(from *notes.Document, def, written string) string {
	text := esc(written)
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
	if first.Link != nil {
		// [R/#Rust/>Book]: straight to the link it matched; several go to
		// the /link page to pick one
		if len(results) > 1 {
			title := itoa(len(results)) + " links"
			return `<a class="zl multi" href="` + esc(s.linkURL(def, from.Rel)) + `" title="` + esc(title) + `">` + text + `</a>`
		}
		href, ok := s.followHref(first, 1)
		if !ok {
			return `<a class="zl broken" href="` + esc(s.linkURL(def, from.Rel)) + `" title="Goes nowhere">` + text + `</a>`
		}
		return `<a class="zl" href="` + esc(href) + `"` + externalAttrs(href) + ` title="` + esc(links.SpanText(first.Link)) + `">` + text + `</a>`
	}
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

// maxFollow bounds chains of > links ([R/>a] matching a line whose link is
// itself a > link).
const maxFollow = 5

// followHref is where the link a follow component matched goes: a URL, a
// file, or the target of a zortex link (resolved from the note it is in).
// Several targets, or too long a chain, go to the /link page.
func (s *Server) followHref(r links.Result, depth int) (string, bool) {
	sp := r.Link
	switch sp.Type {
	case "markdown":
		return s.pathHref(r.Doc, sp.URL)
	case "url":
		return sp.URL, true
	case "filepath":
		return s.pathHref(r.Doc, strings.TrimRight(sp.Path, ".,;:!?"))
	}
	def := sp.Definition
	if s.fileLike(def) {
		return s.pathHref(r.Doc, def)
	}
	results, err := links.Resolve(s.ix, "["+def+"]", links.Options{From: r.Doc})
	if err != nil || len(results) == 0 {
		return "", false
	}
	if results[0].Link != nil {
		if len(results) > 1 || depth >= maxFollow {
			return s.linkURL(def, r.Doc.Rel), true
		}
		return s.followHref(results[0], depth+1)
	}
	return s.noteURL(results[0].Doc.Rel, results[0].Lnum), true
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
	rel, frag, local, dir, ok := s.resolveFile(from, p)
	if !ok || !local {
		return rel, ok
	}
	if !dir && s.isNote(rel) {
		return s.noteURL(rel, 0) + frag, true
	}
	return s.fileURL(rel) + frag, true
}

// rawHref is pathHref for the file's bytes (an image's src), not a viewer.
func (s *Server) rawHref(from *notes.Document, p string) (string, bool) {
	rel, _, local, dir, ok := s.resolveFile(from, p)
	if !ok || !local {
		return rel, ok
	}
	if dir {
		return "", false
	}
	return s.rawURL(rel), true
}

// resolveFile finds the file or folder a path in a note names: its rel (and
// #fragment) when local, or the path itself when external (local false).
func (s *Server) resolveFile(from *notes.Document, p string) (rel, frag string, local, dir, ok bool) {
	var names map[string][]string
	if snap := s.current(); snap != nil {
		names = snap.names
	}
	// Markdown files resolve plain relative paths from their own folder first
	rel, frag, local, found := s.localRef(from.Rel, p, isMarkdown(from.Rel), names)
	if !local {
		if p == "" || strings.HasPrefix(p, "~") {
			return "", "", false, false, false
		}
		return p, "", false, false, true
	}
	if !found {
		return "", "", true, false, false
	}
	st, err := os.Stat(s.ix.Path(rel))
	if err != nil {
		return "", "", true, false, false
	}
	return rel, frag, true, st.IsDir(), true
}

// imageHTML renders ![./pic.png] and ![./clip.mp4]: the image or video
// itself (a missing file is a broken link, as [./pic.png] would be).
func (s *Server) imageHTML(from *notes.Document, def string) string {
	src, ok := s.rawHref(from, def)
	if !ok {
		return `<a class="zl broken" title="File not found">` + esc(def) + `</a>`
	}
	if resourceKind(extOf(def)) == "video" {
		return `<video class="embed" src="` + esc(src) + `" controls preload="metadata" playsinline title="` + esc(path.Base(def)) + `"></video>`
	}
	return `<img class="embed" src="` + esc(src) + `" alt="` + esc(path.Base(def)) + `" loading="lazy">`
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
