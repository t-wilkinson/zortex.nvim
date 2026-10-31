package notes

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// HTML pages as notes: lua/zortex/core/html.lua, step for step (checked
// against tests/fixtures/html, which the Lua writes). HTMLLines is what
// Neovim writes into .z/html/<path>.zortex; the server reads the page the
// same way, so a link's line numbers agree on both sides.
//
// Only bytes are compared (ASCII case), never runes, so both sides read any
// text the same.

func hset(names ...string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

var (
	hVoid  = hset("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr")
	hRaw   = hset("script", "style", "textarea", "title")
	hDrop  = hset("script", "style", "noscript", "template", "head", "title", "nav", "svg", "math", "button", "select", "textarea", "iframe", "canvas", "object")
	hBlock = hset("html", "body", "main", "article", "section", "header", "footer", "aside", "div", "p", "blockquote",
		"figure", "figcaption", "address", "center", "details", "summary", "form", "fieldset", "ul", "ol", "li", "dl",
		"dt", "dd", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "hr", "table", "caption", "thead", "tbody", "tfoot", "tr", "td", "th")
)

// =============================================================================
// Entities
// =============================================================================

var hNamed = map[string]string{
	"amp": "&", "lt": "<", "gt": ">", "quot": `"`, "apos": "'",
	"nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "", "zwj": "", "zwnj": "",
	"mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
	"ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»",
	"copy": "©", "reg": "®", "trade": "™", "times": "×", "divide": "÷", "middot": "·", "bull": "•",
	"deg": "°", "plusmn": "±", "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈",
	"rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔",
	"euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
	"check": "✓", "cross": "✗", "star": "☆", "hearts": "♥", "infin": "∞", "minus": "−", "prime": "′", "Prime": "″",
	"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ",
	"theta": "θ", "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω",
}

var (
	hEntity = regexp.MustCompile(`&([#0-9A-Za-z]+);`)
	hHexRef = regexp.MustCompile(`^#[xX][0-9A-Fa-f]+$`)
	hDecRef = regexp.MustCompile(`^#[0-9]+$`)
)

func hEntityValue(e string) (string, bool) {
	var n uint64
	var err error
	switch {
	case hHexRef.MatchString(e):
		n, err = strconv.ParseUint(e[2:], 16, 64)
	case hDecRef.MatchString(e):
		n, err = strconv.ParseUint(e[1:], 10, 64)
	default:
		v, ok := hNamed[e]
		return v, ok
	}
	if err != nil || n == 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
		return "", false
	}
	if n == 0xA0 {
		return " ", true
	}
	return string(rune(n)), true
}

func hDecode(s string) string {
	if !strings.Contains(s, "&") {
		return s
	}
	return hEntity.ReplaceAllStringFunc(s, func(m string) string {
		if v, ok := hEntityValue(m[1 : len(m)-1]); ok {
			return v
		}
		return m
	})
}

// =============================================================================
// Parsing
// =============================================================================

type hnode struct {
	tag      string // "" for text
	text     string
	attrs    map[string]string
	children []*hnode
}

var (
	hTagName  = regexp.MustCompile(`^[a-z][a-z0-9-]*`)
	hAttrName = regexp.MustCompile("^[^ \t\n\r\f\v/>=\"']+")
	hUnquoted = regexp.MustCompile("^[^ \t\n\r\f\v>]*")
)

func hParse(text string) *hnode {
	root := &hnode{tag: "#root", attrs: map[string]string{}}
	stack := []*hnode{root}
	low := asciiLower(text)
	n := len(text)
	i := 0

	add := func(node *hnode) {
		top := stack[len(stack)-1]
		top.children = append(top.children, node)
	}
	addText := func(s string) { add(&hnode{text: s}) }
	truncate := func(k int) { stack = stack[:k+1] } // keep stack[0..k]
	closeOpen := func(names, boundary map[string]bool) {
		for k := len(stack) - 1; k >= 1; k-- {
			t := stack[k].tag
			if names[t] {
				truncate(k - 1)
				return
			}
			if boundary[t] {
				return
			}
		}
	}
	li, lists := hset("li"), hset("ul", "ol")
	dtdd, dl := hset("dt", "dd"), hset("dl")
	tr, table := hset("tr"), hset("table", "thead", "tbody", "tfoot")
	cell, row := hset("td", "th"), hset("tr", "table")
	section, tbl := hset("thead", "tbody", "tfoot"), hset("table")
	implied := func(tag string) {
		if hBlock[tag] {
			for k := len(stack) - 1; k >= 1; k-- {
				t := stack[k].tag
				if t == "p" {
					truncate(k - 1)
					break
				} else if hBlock[t] {
					break
				}
			}
		}
		switch {
		case tag == "li":
			closeOpen(li, lists)
		case tag == "dt" || tag == "dd":
			closeOpen(dtdd, dl)
		case tag == "tr":
			closeOpen(tr, table)
		case tag == "td" || tag == "th":
			closeOpen(cell, row)
		case section[tag]:
			closeOpen(section, tbl)
		}
	}
	at := func(k int) byte {
		if k < n {
			return text[k]
		}
		return 0
	}
	find := func(s string, from int) int { // index of s at or after from, -1
		if from > n {
			return -1
		}
		if p := strings.Index(text[from:], s); p >= 0 {
			return from + p
		}
		return -1
	}

	for i < n {
		lt := find("<", i)
		if lt < 0 {
			addText(text[i:])
			break
		}
		if lt > i {
			addText(text[i:lt])
		}
		i = lt
		switch {
		case strings.HasPrefix(text[i:], "<!--"):
			if e := find("-->", i+4); e >= 0 {
				i = e + 3
			} else {
				i = n
			}
		case at(i+1) == '!' || at(i+1) == '?':
			if e := find(">", i+2); e >= 0 {
				i = e + 1
			} else {
				i = n
			}
		case at(i+1) == '/':
			name := ""
			if i+2 <= n {
				name = hTagName.FindString(low[i+2:])
			}
			e := -1
			if name != "" {
				e = find(">", i+2+len(name))
			}
			if e < 0 {
				addText("<")
				i++
			} else {
				i = e + 1
				if !hVoid[name] {
					for k := len(stack) - 1; k >= 1; k-- {
						if stack[k].tag == name {
							truncate(k - 1)
							break
						}
					}
				}
			}
		default:
			name := hTagName.FindString(low[i+1:])
			if name == "" {
				addText("<")
				i++
				continue
			}
			attrs := map[string]string{}
			j := i + 1 + len(name)
			closed, selfClosing := false, false
			for j < n {
				c := text[j]
				switch {
				case isHSpace(c):
					j++
					continue
				case c == '>':
					closed = true
					j++
				case c == '/':
					if at(j+1) == '>' {
						closed, selfClosing = true, true
						j += 2
					} else {
						j++
						continue
					}
				default:
					key := hAttrName.FindString(low[j:])
					if key == "" {
						j++
						continue
					}
					j += len(key)
					k := j
					for k < n && isHSpace(text[k]) {
						k++
					}
					value := ""
					if at(k) == '=' {
						k++
						for k < n && isHSpace(text[k]) {
							k++
						}
						if q := at(k); q == '"' || q == '\'' {
							e := find(string(q), k+1)
							if e < 0 {
								value = text[k+1:]
								k = n
							} else {
								value = text[k+1 : e]
								k = e + 1
							}
						} else {
							value = hUnquoted.FindString(text[k:])
							k += len(value)
						}
						j = k
					}
					if _, seen := attrs[key]; !seen {
						attrs[key] = hDecode(value)
					}
					continue
				}
				break
			}
			if !closed {
				addText("<")
				i++
				continue
			}
			i = j
			implied(name)
			node := &hnode{tag: name, attrs: attrs}
			add(node)
			if hRaw[name] {
				e := -1
				if p := strings.Index(low[i:], "</"+name); p >= 0 {
					e = i + p
				}
				if e < 0 {
					node.children = []*hnode{{text: text[i:]}}
					i = n
				} else {
					node.children = []*hnode{{text: text[i:e]}}
					if gt := find(">", e); gt >= 0 {
						i = gt + 1
					} else {
						i = n
					}
				}
			} else if !hVoid[name] && !selfClosing {
				stack = append(stack, node)
			}
		}
	}
	return root
}

// =============================================================================
// Text
// =============================================================================

var (
	hSpaces  = regexp.MustCompile("[ \t\n\r\f\v]+")
	hRuns    = regexp.MustCompile(" +")
	hScheme  = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.\-]*:`)
	hLangRe  = regexp.MustCompile(`language-([A-Za-z0-9_+#.\-]+)`)
	hLang2Re = regexp.MustCompile(`lang-([A-Za-z0-9_+#.\-]+)`)
)

func hCollapse(s string) string { return hSpaces.ReplaceAllString(s, " ") }

func hFind(node *hnode, tag string) *hnode {
	for _, c := range node.children {
		if c.tag == tag {
			return c
		}
		if c.tag != "" {
			if f := hFind(c, tag); f != nil {
				return f
			}
		}
	}
	return nil
}

func hRawText(node *hnode, b *strings.Builder) {
	for _, c := range node.children {
		switch {
		case c.tag == "":
			b.WriteString(c.text)
		case c.tag == "br":
			b.WriteString("\n")
		default:
			hRawText(c, b)
		}
	}
}

func hPlain(node *hnode) string {
	var b strings.Builder
	hRawText(node, &b)
	return htrim(hCollapse(hDecode(hCollapse(b.String()))))
}

func hLeadTrail(inner string) (string, string) {
	lead, trail := "", ""
	if inner != "" && isHSpace(inner[0]) {
		lead = " "
	}
	if inner != "" && isHSpace(inner[len(inner)-1]) {
		trail = " "
	}
	return lead, trail
}

func hWrap(inner, mark string) string {
	core := htrim(inner)
	if core == "" {
		return inner
	}
	lead, trail := hLeadTrail(inner)
	return lead + mark + core + mark + trail
}

func hResolveURL(u, dir string) string {
	if u == "" || u[0] == '/' || u[0] == '#' || u[0] == '?' || hScheme.MatchString(u) {
		return u
	}
	p, rest := u, ""
	if k := strings.IndexAny(u, "?#"); k >= 0 {
		p, rest = u[:k], u[k:]
	}
	notSlash := func(r rune) bool { return r == '/' }
	parts := strings.FieldsFunc(dir, notSlash)
	for _, s := range strings.FieldsFunc(p, notSlash) {
		switch s {
		case "..":
			if len(parts) == 0 {
				return u
			}
			parts = parts[:len(parts)-1]
		case ".":
		default:
			parts = append(parts, s)
		}
	}
	out := strings.Join(parts, "/")
	if strings.HasSuffix(p, "/") && out != "" {
		out += "/"
	}
	return out + rest
}

type hConv struct{ dir string }

func (h *hConv) urlPart(u string) string {
	u = hResolveURL(htrim(u), h.dir)
	return strings.ReplaceAll(strings.ReplaceAll(u, " ", "%20"), ")", "%29")
}

func (h *hConv) inline(node *hnode) string {
	if node.tag == "" {
		return hDecode(hCollapse(node.text))
	}
	tag := node.tag
	switch {
	case hDrop[tag]:
		return ""
	case tag == "br":
		return "\n"
	case tag == "img":
		alt := htrim(hCollapse(node.attrs["alt"]))
		src := h.urlPart(node.attrs["src"])
		if src == "" {
			return alt
		}
		return "![" + alt + "](" + src + ")"
	}
	var b strings.Builder
	for _, c := range node.children {
		b.WriteString(h.inline(c))
	}
	inner := b.String()
	switch tag {
	case "strong", "b":
		return hWrap(inner, "**")
	case "em", "i":
		return hWrap(inner, "*")
	case "code", "kbd", "samp", "tt":
		return hWrap(inner, "`")
	case "a":
		href := h.urlPart(node.attrs["href"])
		core := htrim(hCollapse(strings.ReplaceAll(inner, "\n", " ")))
		if href == "" || href[0] == '#' || strings.HasPrefix(asciiLower(href), "javascript:") || core == "" {
			return inner
		}
		lead, trail := hLeadTrail(inner)
		if core == href {
			return lead + href + trail
		}
		return lead + "[" + core + "](" + href + ")" + trail
	}
	return inner
}

// =============================================================================
// Blocks
// =============================================================================

type hCtx struct {
	prefix string
	tight  bool
}

type hWriter struct {
	lines     []string
	wantBlank bool
}

func (w *hWriter) emit(ctx hCtx, line string) {
	if w.wantBlank && len(w.lines) > 0 && w.lines[len(w.lines)-1] != "" {
		w.lines = append(w.lines, "")
	}
	w.wantBlank = false
	w.lines = append(w.lines, ctx.prefix+line)
}

func (w *hWriter) blank(ctx hCtx) {
	if !ctx.tight {
		w.wantBlank = true
	}
}

func hPieces(text string) []string {
	var out []string
	for _, part := range strings.Split(text, "\n") {
		if p := hRuns.ReplaceAllString(htrim(part), " "); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func hOneLine(text string) string {
	return hRuns.ReplaceAllString(htrim(strings.ReplaceAll(text, "\n", " ")), " ")
}

func (h *hConv) pre(w *hWriter, node *hnode, ctx hCtx) {
	var b strings.Builder
	hRawText(node, &b)
	raw := hDecode(b.String())
	raw = strings.ReplaceAll(strings.ReplaceAll(raw, "\r\n", "\n"), "\r", "\n")
	raw = strings.TrimPrefix(raw, "\n")
	j := len(raw)
	for j > 0 && isHSpace(raw[j-1]) {
		j--
	}
	raw = raw[:j]
	class := node.attrs["class"]
	if code := hFind(node, "code"); code != nil {
		if c, ok := code.attrs["class"]; ok {
			class += " " + c
		}
	}
	lang := ""
	if m := hLangRe.FindStringSubmatch(class); m != nil {
		lang = m[1]
	} else if m := hLang2Re.FindStringSubmatch(class); m != nil {
		lang = m[1]
	}
	fence := "```"
	if strings.Contains(raw, "```") {
		fence = "````"
	}
	w.blank(ctx)
	w.emit(ctx, fence+lang)
	if raw != "" {
		for _, line := range strings.Split(raw, "\n") {
			w.emit(ctx, line)
		}
	}
	w.emit(ctx, fence)
	w.blank(ctx)
}

func (h *hConv) item(w *hWriter, li *hnode, ctx hCtx, depth int, marker string) {
	indent := strings.Repeat("  ", depth)
	first := true
	var buf strings.Builder
	out := func(text string) {
		for _, p := range hPieces(text) {
			if first {
				w.emit(ctx, indent+marker+" "+p)
				first = false
			} else {
				w.emit(ctx, indent+"  "+p)
			}
		}
	}
	flush := func() {
		out(buf.String())
		buf.Reset()
	}
	head := func() {
		if first {
			w.emit(ctx, indent+marker)
			first = false
		}
	}
	for _, c := range li.children {
		switch {
		case c.tag == "" || !hBlock[c.tag]:
			buf.WriteString(h.inline(c))
		case c.tag == "ul" || c.tag == "ol":
			flush()
			head()
			h.list(w, c, ctx, depth+1)
		case c.tag == "pre":
			flush()
			head()
			h.pre(w, c, hCtx{prefix: ctx.prefix + indent + "  ", tight: true})
		case !hDrop[c.tag]:
			flush()
			out(h.inline(c))
		}
	}
	flush()
}

func (h *hConv) list(w *hWriter, node *hnode, ctx hCtx, depth int) {
	if depth == 0 {
		w.blank(ctx)
	}
	count := 0
	for _, c := range node.children {
		switch c.tag {
		case "li":
			count++
			marker := "-"
			if node.tag == "ol" {
				marker = fmt.Sprintf("%d.", count)
			}
			h.item(w, c, ctx, depth, marker)
		case "ul", "ol":
			h.list(w, c, ctx, depth+1)
		}
	}
	if depth == 0 {
		w.blank(ctx)
	}
}

func hRows(node *hnode, out []*hnode) []*hnode {
	for _, c := range node.children {
		switch c.tag {
		case "tr":
			out = append(out, c)
		case "thead", "tbody", "tfoot":
			out = hRows(c, out)
		}
	}
	return out
}

// a note's table has no escape for "|" in a cell: "¦" reads as one
func (h *hConv) table(w *hWriter, node *hnode, ctx hCtx) {
	w.blank(ctx)
	first := true
	for _, tr := range hRows(node, nil) {
		var cells []string
		heads := true
		for _, c := range tr.children {
			if c.tag == "td" || c.tag == "th" {
				cells = append(cells, strings.ReplaceAll(hOneLine(h.inline(c)), "|", "¦"))
				heads = heads && c.tag == "th"
			}
		}
		if len(cells) > 0 {
			w.emit(ctx, "| "+strings.Join(cells, " | ")+" |")
			if first && heads {
				w.emit(ctx, "|"+strings.Repeat("---|", len(cells))) // a header row
			}
			first = false
		}
	}
	w.blank(ctx)
}

func (h *hConv) block(w *hWriter, node *hnode, ctx hCtx) {
	tag := node.tag
	level := 0
	if len(tag) == 2 && tag[0] == 'h' && tag[1] >= '1' && tag[1] <= '6' {
		level = int(tag[1] - '0')
	}
	switch {
	case hDrop[tag]:
	case level > 0:
		if text := hOneLine(h.inline(node)); text != "" {
			w.blank(ctx)
			w.emit(ctx, strings.Repeat("#", level)+" "+text)
			w.blank(ctx)
		}
	case tag == "ul" || tag == "ol":
		h.list(w, node, ctx, 0)
	case tag == "pre":
		h.pre(w, node, ctx)
	case tag == "hr":
		w.blank(ctx)
		w.emit(ctx, "---")
		w.blank(ctx)
	case tag == "table":
		h.table(w, node, ctx)
	case tag == "blockquote":
		w.blank(ctx)
		h.container(w, node, hCtx{prefix: ctx.prefix + "> ", tight: true})
		w.blank(ctx)
	case tag == "dl":
		w.blank(ctx)
		for _, c := range node.children {
			if c.tag == "dt" || c.tag == "dd" {
				lead := "  "
				if c.tag == "dt" {
					lead = "- "
				}
				for _, p := range hPieces(h.inline(c)) {
					w.emit(ctx, lead+p)
					lead = "  "
				}
			}
		}
		w.blank(ctx)
	default:
		h.container(w, node, ctx)
	}
}

func (h *hConv) container(w *hWriter, node *hnode, ctx hCtx) {
	var buf strings.Builder
	flush := func() {
		ps := hPieces(buf.String())
		buf.Reset()
		if len(ps) > 0 {
			w.blank(ctx)
			for _, p := range ps {
				w.emit(ctx, p)
			}
			w.blank(ctx)
		}
	}
	for _, c := range node.children {
		if c.tag == "" || !hBlock[c.tag] {
			buf.WriteString(h.inline(c))
		} else {
			flush()
			h.block(w, c, ctx)
		}
	}
	flush()
}

// =============================================================================
// The note
// =============================================================================

// RawURL is "/raw/" + rel with what a URL can't hold escaped (as the Lua).
func RawURL(rel string) string {
	var b strings.Builder
	b.WriteString("/raw/")
	for i := 0; i < len(rel); i++ {
		c := rel[i]
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.IndexByte("._~/-", c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// HTMLLines is the page text (the notes folder's rel) as a note's lines.
func HTMLLines(text, rel string) []string {
	text = strings.TrimPrefix(text, "\uFEFF")
	root := hParse(text)
	stem := docStem(rel)
	title := ""
	if t := hFind(root, "title"); t != nil {
		title = hPlain(t)
	}
	if title == "" {
		if h1 := hFind(root, "h1"); h1 != nil {
			title = hPlain(h1)
		}
	}
	if title == "" {
		title = stem
	}
	lines := []string{"@@" + title}
	if asciiLower(stem) != asciiLower(title) {
		lines = append(lines, "@@"+stem)
	}
	lines = append(lines, "", "From ["+rel+"]("+RawURL(rel)+")", "")

	dir := ""
	if k := strings.LastIndexByte(rel, '/'); k >= 0 {
		dir = rel[:k]
	}
	h := &hConv{dir: dir}
	w := &hWriter{}
	body := hFind(root, "body")
	if body == nil {
		body = root
	}
	h.container(w, body, hCtx{})
	s, e := 0, len(w.lines)
	for s < e && w.lines[s] == "" {
		s++
	}
	for e > s && w.lines[e-1] == "" {
		e--
	}
	return append(lines, w.lines[s:e]...)
}
