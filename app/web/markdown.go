package web

import (
	"html/template"
	"regexp"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Markdown files (.md, .markdown) render with the note renderer in Markdown
// mode: the Zortex grammar already covers headings, lists, tasks, code and
// $$ math blocks, $inline$ math, tables, quotes, footnotes and emphasis, so
// this file only adds what Markdown has and notes don't:
//
//   - YAML front matter (folded away), --- rules and setext headings
//   - consecutive text lines flow as one paragraph (each line keeps its
//     L<n> anchor), with "  " or "\" hard breaks
//   - images ![alt](src) and reference links [text][id], [text] with their
//     [id]: url definitions; any other [brackets] are text, not zortex links
//   - GitHub-style heading ids, so [x](other.md#some-heading) lands
//   - "Key:" and "Label:" lines are plain text, @ lines aren't a note header
//
// Raw HTML is shown as text (the page is on our origin; an HTML file is the
// way to get a sandboxed page). Math is typeset by math.js like a note's.

type mdRef struct{ URL, Title string }

type mdDoc struct {
	refs     map[string]mdRef // lower-cased label -> target
	refLines map[int]bool     // [id]: url lines, not shown
	front    int              // last line of the front matter (0: none)
	slugs    map[string]int   // heading ids handed out
}

var (
	mdRefDef = regexp.MustCompile(`^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*<?([^\s>]+)>?(?:[ \t]+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?[ \t]*$`)
	mdBullet = regexp.MustCompile(`^[ \t]*[*+][ \t]`)
	mdRule   = regexp.MustCompile(`^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$`)
	mdSetext = regexp.MustCompile(`^ {0,3}(=+|-+)[ \t]*$`)
)

func isMarkdown(rel string) bool { return linkingExts[extOf(rel)] }

// renderMarkdown is the HTML body of a Markdown file.
func (s *Server) renderMarkdown(rel, text string) template.HTML {
	text = strings.ReplaceAll(strings.TrimPrefix(text, "\ufeff"), "\r\n", "\n")
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	// Markdown's "*" and "+" bullets are "-" in a note (one byte for one, so
	// columns stay put)
	for i, l := range lines {
		if mdBullet.MatchString(l) && !mdRule.MatchString(l) {
			j := len(l) - len(strings.TrimLeft(l, " \t"))
			lines[i] = l[:j] + "-" + l[j+1:]
		}
	}
	doc := notes.FromLines(rel, lines)
	r := &noteRenderer{s: s, doc: doc, ast: doc.Parse(), md: scanMarkdown(lines)}
	r.ast.Header = syntax.Header{} // "@tag" lines are text in Markdown
	r.render()
	return template.HTML(r.b.String())
}

func scanMarkdown(lines []string) *mdDoc {
	md := &mdDoc{refs: map[string]mdRef{}, refLines: map[int]bool{}, slugs: map[string]int{}}
	if len(lines) > 1 && strings.TrimSpace(lines[0]) == "---" {
		for i := 1; i < len(lines); i++ {
			if t := strings.TrimSpace(lines[i]); t == "---" || t == "..." {
				md.front = i + 1
				break
			}
		}
	}
	fence := ""
	for i, line := range lines {
		t := strings.TrimSpace(line)
		if fence != "" {
			if strings.HasPrefix(t, fence) {
				fence = ""
			}
			continue
		}
		if strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			fence = t[:3]
			continue
		}
		if i < md.front {
			continue
		}
		if m := mdRefDef.FindStringSubmatch(line); m != nil {
			label := strings.ToLower(strings.Join(strings.Fields(m[1]), " "))
			if _, dup := md.refs[label]; !dup { // the first definition wins
				md.refs[label] = mdRef{URL: m[2], Title: m[3] + m[4] + m[5]}
			}
			md.refLines[i+1] = true
		}
	}
	return md
}

// slug is a GitHub-style heading id: lower case, punctuation dropped,
// spaces to dashes, "-1", "-2" for repeats.
func (md *mdDoc) slug(text string) string {
	var b strings.Builder
	for _, c := range strings.ToLower(strings.TrimSpace(text)) {
		switch {
		case c == ' ':
			b.WriteByte('-')
		case c == '-' || c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c > 127:
			b.WriteRune(c)
		}
	}
	id := b.String()
	n := md.slugs[id]
	md.slugs[id] = n + 1
	if n > 0 {
		id += "-" + itoa(n)
	}
	return id
}

// headingText is a heading line's text without its markup, for its slug.
func headingText(line string, spans []syntax.Span, from, to int) string {
	var b strings.Builder
	pos := from
	var walk func(spans []syntax.Span, to int)
	walk = func(spans []syntax.Span, to int) {
		for _, sp := range spans {
			if sp.S < pos || sp.E > to {
				continue
			}
			b.WriteString(line[pos:sp.S])
			switch {
			case len(sp.Children) > 0:
				pos = sp.InnerS
				walk(sp.Children, sp.InnerE)
				b.WriteString(line[pos:sp.InnerE])
			case sp.Type == "code" || sp.Type == "math" || sp.Type == "bold" || sp.Type == "italic":
				b.WriteString(line[sp.InnerS:sp.InnerE])
			case sp.Text != "":
				b.WriteString(sp.Text)
			default:
				b.WriteString(line[sp.S:sp.E])
			}
			pos = sp.E
		}
	}
	walk(spans, to)
	if pos < to {
		b.WriteString(line[pos:to])
	}
	return strings.TrimRight(strings.TrimSpace(b.String()), "#")
}

// mdSpans parses line[from:to] the Markdown way: "![alt](src)" is an image
// (the zortex grammar would read "![alt]" as a live link), "[text][id]" and
// "[id]" are reference links when id is defined, other brackets are text.
func (r *noteRenderer) mdSpans(line string, from, to int) []syntax.Span {
	// "![" -> " [" keeps the offsets; the "!" is put back on the image span
	spans := syntax.Inline(strings.ReplaceAll(line, "![", " ["), from, to)
	return r.md.fixSpans(line, spans)
}

func (md *mdDoc) fixSpans(line string, spans []syntax.Span) []syntax.Span {
	out := make([]syntax.Span, 0, len(spans))
	for i := 0; i < len(spans); i++ {
		sp := spans[i]
		if len(sp.Children) > 0 {
			sp.Children = md.fixSpans(line, sp.Children)
		}
		bang := sp.S > 0 && line[sp.S-1] == '!'
		switch sp.Type {
		case "attribute", "tag_search", "hidden", "time":
			sp.Type = "text" // zortex-only syntax
		case "markdown":
			sp.URL, sp.Value = mdTarget(sp.URL)
			if bang {
				sp.Type, sp.S = "md_image", sp.S-1
			}
		case "link", "live_link":
			// [text][id] (the zortex grammar sees two links), then [id]
			label, text, end := sp.Definition, sp.Definition, sp.E
			if i+1 < len(spans) && spans[i+1].S == sp.E && (spans[i+1].Type == "link" || spans[i+1].Type == "live_link") {
				if next := spans[i+1].Definition; next != "" {
					label = next
				}
				end = spans[i+1].E
			}
			ref, ok := md.refs[strings.ToLower(strings.Join(strings.Fields(label), " "))]
			if !ok {
				sp.Type = "text" // shown as written
				break
			}
			if end != sp.E {
				i++
			}
			sp.Type, sp.E, sp.Text, sp.URL, sp.Value = "markdown", end, text, ref.URL, ref.Title
			if bang {
				sp.Type, sp.S = "md_image", sp.S-1
			}
		}
		out = append(out, sp)
	}
	return out
}

// mdTarget splits a link destination from its optional "title".
func mdTarget(u string) (url, title string) {
	u = strings.TrimSpace(u)
	if strings.HasPrefix(u, "<") {
		if i := strings.IndexByte(u, '>'); i > 0 {
			return u[1:i], strings.Trim(strings.TrimSpace(u[i+1:]), `"'()`)
		}
	}
	if i := strings.IndexAny(u, " \t"); i > 0 {
		return u[:i], strings.Trim(strings.TrimSpace(u[i:]), `"'()`)
	}
	return u, ""
}

// mdImage renders ![alt](src): a local image or video, or an external one.
func (r *noteRenderer) mdImage(sp *syntax.Span) string {
	src, ok := r.s.rawHref(r.doc, sp.URL)
	if !ok {
		return `<a class="md broken" title="File not found">` + esc(sp.Text) + `</a>`
	}
	title := ""
	if sp.Value != "" {
		title = ` title="` + esc(sp.Value) + `"`
	}
	if resourceKind(extOf(sp.URL)) == "video" {
		return `<video class="embed" src="` + esc(src) + `" controls preload="metadata" playsinline` + title + `></video>`
	}
	return `<img class="embed" src="` + esc(src) + `" alt="` + esc(sp.Text) + `"` + title + ` loading="lazy">`
}

// mdBlock renders line i the Markdown way when it isn't a note line:
// front matter, reference definitions, rules, setext headings and paragraph
// text. It returns the index of the last line used, or -1 to render line i
// as a note line.
func (r *noteRenderer) mdBlock(i int) int {
	md, lines, ast := r.md, r.doc.Lines, r.ast
	lnum, line, d := i+1, lines[i], ast.Lines[i]
	id := itoa(lnum)
	switch {
	case lnum <= md.front:
		r.mdEndPara()
		r.w(`<details class="frontmatter" id="L1"><summary>front matter</summary><pre><code>`)
		for k := 1; k < md.front-1; k++ {
			r.w(`<span class="cl" id="L`, itoa(k+1), `">`, esc(lines[k]), "\n</span>")
		}
		r.w(`</code></pre></details><span class="anchor" id="L`, itoa(md.front), `"></span>`)
		return md.front - 1
	case md.refLines[lnum]:
		r.mdEndPara()
		r.w(`<span class="anchor" id="L`, id, `"></span>`)
		return i
	case !r.mdParaLine(d, line):
		if mdRule.MatchString(line) && (d.Kind == syntax.KindText || d.Kind == syntax.KindItem || d.Kind == syntax.KindBlank) {
			r.mdEndPara()
			r.w(`<hr class="ln" id="L`, id, `">`)
			return i
		}
		r.mdEndPara()
		return -1
	}
	// a paragraph line; a setext underline below a paragraph's first line
	// makes it a heading
	if !r.inPara && i+1 < len(lines) && !md.refLines[lnum+1] {
		if m := mdSetext.FindStringSubmatch(lines[i+1]); m != nil {
			h := "1"
			if m[1][0] == '-' {
				h = "2"
			}
			from := len(line) - len(strings.TrimLeft(line, " \t"))
			spans := r.mdSpans(line, from, len(line))
			slug := md.slug(headingText(line, spans, from, len(line)))
			r.w(`<h`, h, ` class="ln" id="L`, id, `"><span class="anchor" id="`, esc(slug), `"></span>`,
				r.inline(line, spans, from, len(strings.TrimRight(line, " \t"))),
				`<a class="pin" href="#`, esc(slug), `" aria-label="Link to this section">#</a></h`, h, `>`,
				`<span class="anchor" id="L`, itoa(lnum+1), `"></span>`)
			return i + 1
		}
	}
	if !r.inPara {
		r.w(`<p class="md-p">`)
		r.inPara = true
	} else {
		r.w("\n")
	}
	from := len(line) - len(strings.TrimLeft(line, " \t"))
	to := len(line)
	br := ""
	switch {
	case strings.HasSuffix(line, "  "):
		to, br = len(strings.TrimRight(line, " ")), "<br>"
	case strings.HasSuffix(line, `\`) && !strings.HasSuffix(line, `\\`):
		to, br = len(line)-1, "<br>"
	}
	r.w(`<span class="ln text" id="L`, id, `">`, r.inline(line, r.mdSpans(line, from, to), from, to), `</span>`, br)
	return i
}

// mdParaLine: is this line paragraph text (not a list item, heading, quote,
// table, footnote, rule or blank)?
func (r *noteRenderer) mdParaLine(d *syntax.Line, line string) bool {
	switch d.Kind {
	case syntax.KindText, syntax.KindLabel, syntax.KindTag, syntax.KindArticle:
		return d.Item == nil && !mdRule.MatchString(line) && strings.TrimSpace(line) != ""
	}
	return false
}

func (r *noteRenderer) mdEndPara() {
	if r.inPara {
		r.w(`</p>`)
		r.inPara = false
	}
}

// mdText renders a link's text: code, math and emphasis, no nested links.
func (r *noteRenderer) mdText(text string) string {
	if r.md == nil {
		return esc(text)
	}
	var keep func(spans []syntax.Span) []syntax.Span
	keep = func(spans []syntax.Span) []syntax.Span {
		var out []syntax.Span
		for _, sp := range spans {
			switch sp.Type {
			case "code", "math", "bold", "italic":
				sp.Children = keep(sp.Children)
				out = append(out, sp)
			}
		}
		return out
	}
	return r.inline(text, keep(syntax.Inline(text, 0, len(text))), 0, len(text))
}
