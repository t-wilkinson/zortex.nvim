package syntax

import "strings"

// Span is an inline span. S and E are 0-based byte offsets (E exclusive).
// Which other fields are set depends on Type:
//
//	link, live_link   Definition             [Projects/#Heading], ![Article]
//	                  Text, DefS             [shown text](P/#Heading), ![alt](./pic.png)
//	tag_search        Content                     @[cars parts], !@[...] (Embed)
//	markdown          Text, URL              [text](https://...)
//	footnote_ref      ID                     [^1]
//	url               URL                    https://...
//	filepath          Path                   ./img.png, ~/notes
//	attribute         Key, Value (HasValue)  @size(lg), @p1
//	code              InnerS, InnerE         `code`
//	math              InnerS, InnerE, Display    $x$, $$x$$
//	bold, italic      InnerS, InnerE, Children   **x**, *x*
//	time              Value                  14:00
type Span struct {
	Type       string
	S, E       int
	InnerS     int
	InnerE     int
	Display    bool
	Embed      bool // tag_search written !@[...]: shown in place
	Definition string
	DefS       int // where Definition starts, for links written [text](definition)
	Content    string
	Text       string
	URL        string
	ID         string
	Path       string
	Key        string
	Value      string
	HasValue   bool
	Children   []Span
}

func wordStart(line string, i int) bool {
	if i == 0 {
		return true
	}
	switch line[i-1] {
	case '(', '[', '{', '"', '\'':
		return true
	}
	return isSpace(line[i-1])
}

func boundaryAfter(line string, j int) bool {
	return j >= len(line) || !isAlnum(line[j])
}

// runUntil returns the length of the run of bytes from i that are not in stop.
func runUntil(line string, i int, stop func(byte) bool) int {
	n := 0
	for i+n < len(line) && !stop(line[i+n]) {
		n++
	}
	return n
}

func notCloseBracket(b byte) bool { return b == ']' }

func scanCode(line string, i int) *Span {
	n := countLeading(line[i:], '`')
	ticks := line[i : i+n]
	idx := strings.Index(line[i+n:], ticks)
	if idx <= 0 {
		return nil
	}
	c := i + n + idx
	return &Span{Type: "code", S: i, E: c + n, InnerS: i + n, InnerE: c}
}

func scanMath(line string, i int) *Span {
	if at(line, i+1) == '$' {
		idx := strings.Index(line[i+2:], "$$")
		if idx <= 0 {
			return nil
		}
		c := i + 2 + idx
		return &Span{Type: "math", Display: true, S: i, E: c + 2, InnerS: i + 2, InnerE: c}
	}
	if i > 0 && isAlnum(line[i-1]) {
		return nil
	}
	first := at(line, i+1)
	if first == 0 || isSpace(first) || first == '$' {
		return nil
	}
	from := i + 1
	for {
		idx := strings.IndexByte(line[from:], '$')
		if idx < 0 {
			return nil
		}
		c := from + idx
		if !isSpace(line[c-1]) && boundaryAfter(line, c+1) {
			return &Span{Type: "math", S: i, E: c + 1, InnerS: i + 1, InnerE: c}
		}
		from = c + 1
	}
}

func scanLiveLink(line string, i int) *Span {
	if at(line, i+1) == '@' && at(line, i+2) == '[' {
		// !@[tags]: the tag search shown in place (a table on the web)
		sp := scanAt(line, i+1)
		if sp != nil {
			sp.S, sp.Embed = i, true
		}
		return sp
	}
	if at(line, i+1) != '[' {
		return nil
	}
	n := runUntil(line, i+2, notCloseBracket)
	if at(line, i+2+n) != ']' {
		return nil
	}
	// ![alt](target): Markdown's image form; the alt text is optional
	if at(line, i+3+n) == '(' {
		d := i + 4 + n
		un := runUntil(line, d, func(b byte) bool { return b == ')' })
		if un > 0 && at(line, d+un) == ')' {
			return &Span{Type: "live_link", S: i, E: d + un + 1, Definition: line[d : d+un], Text: line[i+2 : i+2+n], DefS: d}
		}
	}
	if n == 0 {
		return nil
	}
	return &Span{Type: "live_link", S: i, E: i + n + 3, Definition: line[i+2 : i+2+n]}
}

func scanAt(line string, i int) *Span {
	if at(line, i+1) == '[' {
		n := runUntil(line, i+2, notCloseBracket)
		if n == 0 || at(line, i+2+n) != ']' {
			return nil
		}
		content := line[i+2 : i+2+n]
		return &Span{Type: "tag_search", S: i, E: i + n + 3, Content: content}
	}
	if !wordStart(line, i) {
		return nil
	}
	if !isWordOrUnderscore(at(line, i+1)) {
		return nil
	}
	k := i + 2
	for k < len(line) && (isWordOrUnderscore(line[k]) || line[k] == '-') {
		k++
	}
	key := line[i+1 : k]
	if at(line, k) == '(' {
		n := runUntil(line, k+1, func(b byte) bool { return b == ')' })
		if at(line, k+1+n) == ')' {
			return &Span{Type: "attribute", S: i, E: k + n + 2, Key: key, Value: line[k+1 : k+1+n], HasValue: true}
		}
	}
	return &Span{Type: "attribute", S: i, E: k, Key: key}
}

// IsLinkTarget reports whether the target of "[text](target)" is a zortex
// link rather than a URL or a file (which keep the Markdown link): the same
// rules as core/syntax.is_link_target in the plugin.
func IsLinkTarget(target string) bool {
	t := Trim(target)
	if t == "" || strings.HasPrefix(t, "www.") {
		return false
	}
	// a scheme: https:, mailto:
	if isAlpha(t[0]) {
		k := 1
		for k < len(t) && (isAlnum(t[k]) || t[k] == '+' || t[k] == '.' || t[k] == '-') {
			k++
		}
		if k < len(t) && t[k] == ':' {
			return false
		}
	}
	// a typed component, first or after a "/"
	typed := func(b byte) bool { return strings.IndexByte("#:*%>@-", b) >= 0 }
	if typed(t[0]) {
		return true
	}
	for k := 0; k+1 < len(t); k++ {
		if t[k] == '/' && typed(t[k+1]) {
			return true
		}
	}
	// a path: "/", "./", "../", "~/" (and "~./", "~../", as the plugin's pattern)
	p := t
	p = strings.TrimPrefix(p, "~")
	p = strings.TrimPrefix(p, ".")
	p = strings.TrimPrefix(p, ".")
	if strings.HasPrefix(p, "/") {
		return false
	}
	// a file extension at the end, before a #fragment or a "title"
	for k := 0; k+1 < len(t); k++ {
		if t[k] != '.' || !isAlpha(t[k+1]) {
			continue
		}
		j := k + 2
		for j < len(t) && isAlnum(t[j]) {
			j++
		}
		if j == len(t) || t[j] == '#' || isSpace(t[j]) {
			return false
		}
	}
	return true
}

func scanBracket(line string, i int) *Span {
	// footnote reference: [^id]
	if k, ok := footnoteID(line, i); ok {
		return &Span{Type: "footnote_ref", S: i, E: k + 1, ID: line[i+2 : k]}
	}
	// markdown link: [text](url)
	tn := runUntil(line, i+1, notCloseBracket)
	if at(line, i+1+tn) == ']' && at(line, i+2+tn) == '(' {
		un := runUntil(line, i+3+tn, func(b byte) bool { return b == ')' })
		if un > 0 && at(line, i+3+tn+un) == ')' {
			if tn > 0 && IsLinkTarget(line[i+3+tn:i+3+tn+un]) {
				// [text](P/#1.4): a zortex link shown as its text
				return &Span{Type: "link", S: i, E: i + tn + un + 4, Definition: line[i+3+tn : i+3+tn+un], Text: line[i+1 : i+1+tn], DefS: i + 3 + tn}
			}
			return &Span{Type: "markdown", S: i, E: i + tn + un + 4, Text: line[i+1 : i+1+tn], URL: line[i+3+tn : i+3+tn+un]}
		}
	}
	// zortex link: [definition]
	if tn > 0 && at(line, i+1+tn) == ']' {
		content := line[i+1 : i+1+tn]
		if content[0] == '^' {
			return nil
		}
		if tn == 1 && strings.IndexByte(" xX-.", content[0]) >= 0 {
			return nil
		}
		return &Span{Type: "link", S: i, E: i + tn + 2, Definition: content}
	}
	return nil
}

func urlStop(b byte) bool {
	return isSpace(b) || b == ']' || b == ')' || b == '}' || b == ';'
}

func scanURL(line string, i int) *Span {
	rest := line[i:]
	var p int
	switch {
	case strings.HasPrefix(rest, "https://"):
		p = 8
	case strings.HasPrefix(rest, "http://"):
		p = 7
	default:
		return nil
	}
	n := runUntil(line, i+p, urlStop)
	if n == 0 {
		return nil
	}
	return &Span{Type: "url", S: i, E: i + p + n, URL: line[i : i+p+n]}
}

func emphasis(line string, i int, marker, kind string) *Span {
	n := len(marker)
	inner := i + n
	first := at(line, inner)
	if first == 0 || isSpace(first) || first == '*' {
		return nil
	}
	from := inner
	for {
		idx := strings.Index(line[from:], marker)
		if idx < 0 {
			return nil
		}
		c := from + idx
		if c > inner && !isSpace(line[c-1]) && at(line, c+n) != '*' {
			return &Span{Type: kind, S: i, E: c + n, InnerS: inner, InnerE: c}
		}
		from = c + 1
	}
}

func scanStar(line string, i int) *Span {
	if at(line, i+1) == '*' {
		return emphasis(line, i, "**", "bold")
	}
	if i > 0 && isAlnum(line[i-1]) {
		return nil
	}
	return emphasis(line, i, "*", "italic")
}

func pathStop(b byte) bool { return isSpace(b) || b == ']' || b == ')' }

func scanFilepath(line string, i int) *Span {
	if !wordStart(line, i) {
		return nil
	}
	end := -1
	switch {
	case at(line, i) == '~' && at(line, i+1) == '/':
		if n := runUntil(line, i+2, pathStop); n > 0 {
			end = i + 2 + n
		}
	case at(line, i) == '.':
		p := i + 1
		if at(line, p) == '.' && at(line, p+1) == '/' {
			p += 2
		} else if at(line, p) == '/' {
			p++
		} else {
			p = -1
		}
		if p > 0 {
			if n := runUntil(line, p, pathStop); n > 0 {
				end = p + n
			}
		}
	case at(line, i) == '/':
		c := at(line, i+1)
		if isWordOrUnderscore(c) || c == '~' || c == '.' || c == '-' {
			end = i + 2 + runUntil(line, i+2, pathStop)
		}
	}
	if end < 0 {
		return nil
	}
	return &Span{Type: "filepath", S: i, E: end, Path: line[i:end]}
}

func scanTime(line string, i int) *Span {
	if i > 0 && (isAlnum(line[i-1]) || line[i-1] == ':') {
		return nil
	}
	e := timeAt(line, i)
	if e < 0 || !boundaryAfter(line, e) || at(line, e) == ':' {
		return nil
	}
	return &Span{Type: "time", S: i, E: e, Value: line[i:e]}
}

func scan(line string, i int) *Span {
	switch c := line[i]; {
	case c == '`':
		return scanCode(line, i)
	case c == '$':
		return scanMath(line, i)
	case c == '!':
		return scanLiveLink(line, i)
	case c == '@':
		return scanAt(line, i)
	case c == '[':
		return scanBracket(line, i)
	case c == 'h':
		return scanURL(line, i)
	case c == '*':
		return scanStar(line, i)
	case c == '~' || c == '.' || c == '/':
		return scanFilepath(line, i)
	case isDigit(c):
		return scanTime(line, i)
	}
	return nil
}

// Inline returns the spans of line between byte offsets from and to (to is
// exclusive; pass len(line) for the whole line). Spans never overlap; bold
// and italic spans carry their own Children.
func Inline(line string, from, to int) []Span {
	if to > len(line) {
		to = len(line)
	}
	scanLine := line[:to]
	spans := []Span{}
	for i := from; i < to; {
		sp := scan(scanLine, i)
		if sp == nil {
			i++
			continue
		}
		if sp.Type == "bold" || sp.Type == "italic" {
			sp.Children = Inline(scanLine, sp.InnerS, sp.InnerE)
		}
		spans = append(spans, *sp)
		i = sp.E
	}
	return spans
}

// Walk calls fn for every span, children after their parent.
func Walk(spans []Span, fn func(*Span)) {
	for i := range spans {
		fn(&spans[i])
		if spans[i].Children != nil {
			Walk(spans[i].Children, fn)
		}
	}
}

// Links returns every link and live_link span, in order.
func Links(spans []Span) []Span {
	out := []Span{}
	Walk(spans, func(s *Span) {
		if s.Type == "link" || s.Type == "live_link" {
			out = append(out, *s)
		}
	})
	return out
}

// footnoteID: "[^id]" at i, the id anything but brackets and not starting
// with a space ("[^1]", "[^Smith, 2020]"); returns the index of its "]".
func footnoteID(line string, i int) (int, bool) {
	if at(line, i) != '[' || at(line, i+1) != '^' {
		return 0, false
	}
	k := i + 2
	if k >= len(line) || isSpace(line[k]) || line[k] == ']' || line[k] == '[' {
		return 0, false
	}
	for k < len(line) && line[k] != ']' && line[k] != '[' {
		k++
	}
	if at(line, k) != ']' {
		return 0, false
	}
	return k, true
}
