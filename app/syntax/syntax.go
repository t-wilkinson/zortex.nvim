// Package syntax is the Zortex grammar: line kinds, list items, blocks and
// inline spans, with byte columns.
//
// It is a port of lua/zortex/core/syntax.lua (the specification) and must
// produce the same output: syntax_test.go compares Parse with every file in
// tests/fixtures/ast, which the Lua parser generates. Change the Lua grammar
// first, regenerate the fixtures (nvim --headless -u NONE -l
// tests/gen_ast.lua), then make this package pass again.
//
// Columns are 0-based byte offsets; ends are exclusive. Line numbers are
// 1-based.
package syntax

// Version of the AST format (matches core/syntax.VERSION).
const Version = 1

// Section kinds and their structural levels (constants.SECTION_HIERARCHY).
const (
	KindArticle     = "article"
	KindTag         = "tag"
	KindHeading     = "heading"
	KindBoldHeading = "bold_heading"
	KindLabel       = "label"
	KindItem        = "item"
	KindText        = "text"
	KindBlank       = "blank"
	KindFence       = "fence"
	KindCode        = "code"
	KindMathFence   = "math_fence"
	KindMath        = "math"
	KindTable       = "table"
	KindQuote       = "quote"
	KindFootnote    = "footnote"

	levelBold  = 7
	levelLabel = 8
)

func headingLevel(n int) int {
	if n < 1 {
		return 1
	}
	if n > 6 {
		return 6
	}
	return n
}

// Header is the block of @@names and @tags at the top of a note.
type Header struct {
	Names    []string `json:"names"`
	Tags     []string `json:"tags"`
	TagLines []string `json:"tag_lines"`
	NameLnum int      `json:"name_lnum,omitempty"` // 0 when the note has no @@ name
	LastLnum int      `json:"last_lnum"`
}

// Time is the time prefix of a time item: At, or From and To.
type Time struct {
	At   string `json:"at,omitempty"`
	From string `json:"from,omitempty"`
	To   string `json:"to,omitempty"`
}

// Item describes a list item: "- [ ] text", "1. text", "14:00 text", "- KR1: [x] text".
type Item struct {
	Marker     string `json:"marker"`
	MarkerType string `json:"marker_type"` // bullet | ordered | time
	MarkerCol  int    `json:"marker_col"`
	Time       *Time  `json:"time,omitempty"`
	Key        string `json:"key,omitempty"`
	KeyCol     *int   `json:"key_col,omitempty"`
	Mark       string `json:"mark,omitempty"` // checkbox character
	MarkCol    *int   `json:"mark_col,omitempty"`
	ContentCol int    `json:"content_col"`
}

// Section is a structural line: the article, a heading, bold heading or label.
type Section struct {
	Lnum  int      `json:"lnum"`
	Type  string   `json:"type"`
	Level int      `json:"level"`
	Text  string   `json:"text"`
	Names []string `json:"names,omitempty"`
}

// Block is a multi-line block: code, math or table.
type Block struct {
	Kind   string  `json:"kind"`
	Start  int     `json:"start"`
	Finish int     `json:"finish"`
	Lang   *string `json:"lang,omitempty"`
}

// AST is a parsed note.
type AST struct {
	Version  int        `json:"version"`
	Header   Header     `json:"header"`
	Lines    []*Line    `json:"lines"`
	Sections []*Section `json:"sections"`
	Blocks   []*Block   `json:"blocks"`
}

func intp(v int) *int       { return &v }
func strp(v string) *string { return &v }
func boolp(v bool) *bool    { return &v }

// =============================================================================
// Attributes and queries
// =============================================================================

// balancedParen returns the index after the ")" matching the "(" at i, or -1.
func balancedParen(s string, i int) int {
	depth := 0
	for k := i; k < len(s); k++ {
		switch s[k] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return k + 1
			}
		}
	}
	return -1
}

func isWordOrUnderscore(b byte) bool { return isAlnum(b) || b == '_' }

// StripAttributes removes @key(value) and bare @word tokens that start a
// word: "1.4 - zortex @p1 @size(lg)" -> "1.4 - zortex". "me@example.com" stays.
func StripAttributes(text string) string {
	s := " " + text
	// %s@[%w_]+%b()
	var b []byte
	for i := 0; i < len(s); {
		if isSpace(s[i]) && at(s, i+1) == '@' {
			j := i + 2
			for j < len(s) && isWordOrUnderscore(s[j]) {
				j++
			}
			if j > i+2 && at(s, j) == '(' {
				if k := balancedParen(s, j); k >= 0 {
					i = k
					continue
				}
			}
		}
		b = append(b, s[i])
		i++
	}
	s = string(b)
	// %s@[%w_%-]+
	b = b[:0]
	for i := 0; i < len(s); {
		if isSpace(s[i]) && at(s, i+1) == '@' {
			j := i + 2
			for j < len(s) && (isWordOrUnderscore(s[j]) || s[j] == '-') {
				j++
			}
			if j > i+2 {
				i = j
				continue
			}
		}
		b = append(b, s[i])
		i++
	}
	// %s+ -> " ", then trim
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); {
		if isSpace(b[i]) {
			for i < len(b) && isSpace(b[i]) {
				i++
			}
			out = append(out, ' ')
			continue
		}
		out = append(out, b[i])
		i++
	}
	return Trim(string(out))
}

// SplitQuery splits "a + b" (or) / "a & b" (and) into terms. Spaces around
// the operator are required, so "c++" and "r&d" are single terms.
func SplitQuery(content string) (string, []string) {
	var sep byte
	queryType := "single"
	if containsStr(content, " + ") {
		queryType, sep = "or", '+'
	} else if containsStr(content, " & ") {
		queryType, sep = "and", '&'
	}
	if sep == 0 {
		return queryType, []string{Trim(content)}
	}
	terms := []string{}
	start := -1
	flush := func(end int) {
		if start >= 0 {
			if t := Trim(content[start:end]); t != "" {
				terms = append(terms, t)
			}
			start = -1
		}
	}
	for i := 0; i < len(content); i++ {
		if content[i] == sep {
			flush(i)
		} else if start < 0 {
			start = i
		}
	}
	flush(len(content))
	return queryType, terms
}

func containsStr(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// =============================================================================
// Header
// =============================================================================

func isTagLine(line string) bool { return at(line, 0) == '@' && isAlnum(at(line, 1)) }

// ParseHeader reads the header: @@names and @tags at the top of a note, blank
// lines skipped, ending at the first other line (within maxLines; 50 if <= 0).
func ParseHeader(lines []string, maxLines int) Header {
	h := Header{Names: []string{}, Tags: []string{}, TagLines: []string{}}
	if maxLines <= 0 {
		maxLines = 50
	}
	for i := 0; i < len(lines) && i < maxLines; i++ {
		line, lnum := lines[i], i+1
		switch {
		case len(line) > 2 && line[0] == '@' && line[1] == '@':
			h.Names = append(h.Names, Trim(line[2:]))
			if h.NameLnum == 0 {
				h.NameLnum = lnum
			}
			h.LastLnum = lnum
		case isTagLine(line):
			h.Tags = append(h.Tags, Trim(line[1:]))
			h.TagLines = append(h.TagLines, line)
			h.LastLnum = lnum
		case hasNonSpace(line):
			return h
		}
	}
	return h
}

// =============================================================================
// List items
// =============================================================================

// matchKey matches "Key: " at the start of text: the key and the length
// consumed including ":" and the following whitespace.
func matchKey(text string) (string, int, bool) {
	if !isAlnum(at(text, 0)) {
		return "", 0, false
	}
	colon := -1
	for i := 0; i < len(text); i++ {
		if text[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 1 {
		return "", 0, false
	}
	ws := spaceRun(text, colon+1)
	if ws == 0 {
		return "", 0, false
	}
	key := text[:colon]
	if hasPeriodSpace(key) || len(key) > 60 {
		return "", 0, false
	}
	return key, colon + 1 + ws, true
}

// matchCheckbox matches "[x] text" at the start of text: the mark and the
// length consumed. A checkbox needs text after it.
func matchCheckbox(text string) (string, int, bool) {
	if len(text) < 4 || text[0] != '[' || text[2] != ']' {
		return "", 0, false
	}
	ws := spaceRun(text, 3)
	if ws == 0 || 3+ws >= len(text) {
		return "", 0, false
	}
	return text[1:2], 3 + ws, true
}

// ItemOf parses the list item on a line, or returns nil.
func ItemOf(line string) *Item {
	indent := spaceRun(line, 0)
	rest := line[indent:]
	var it *Item
	consumed := 0

	switch {
	case len(rest) >= 2 && (rest[0] == '-' || rest[0] == '+' || rest[0] == '*') && isSpace(rest[1]):
		it = &Item{Marker: rest[:1], MarkerType: "bullet"}
		consumed = 1 + spaceRun(rest, 1)
	case len(rest) >= 2 && rest[0] == '-' && rest[1] == '[', rest == "-":
		it = &Item{Marker: "-", MarkerType: "bullet"}
		consumed = 1
	default:
		if e1 := timeAt(rest, 0); e1 > 0 {
			j := e1 + spaceRun(rest, e1)
			if at(rest, j) == '-' {
				j++
				j += spaceRun(rest, j)
				if e2 := timeAt(rest, j); e2 > 0 {
					if sp := spaceRun(rest, e2); sp > 0 {
						it = &Item{Marker: rest[:e2], MarkerType: "time", Time: &Time{From: rest[:e1], To: rest[j:e2]}}
						consumed = e2 + sp
					}
				}
			}
			if it == nil {
				if sp := spaceRun(rest, e1); sp > 0 {
					it = &Item{Marker: rest[:e1], MarkerType: "time", Time: &Time{At: rest[:e1]}}
					consumed = e1 + sp
				}
			}
		}
		if it == nil {
			k := 0
			for k < len(rest) && isDigit(rest[k]) {
				k++
			}
			if k > 0 && at(rest, k) == '.' && spaceRun(rest, k+1) > 0 {
				it = &Item{Marker: rest[:k+1], MarkerType: "ordered"}
				consumed = k + 1 + spaceRun(rest, k+1)
			} else if isAlpha(at(rest, 0)) && at(rest, 1) == '.' && spaceRun(rest, 2) > 0 {
				it = &Item{Marker: rest[:2], MarkerType: "ordered"}
				consumed = 2 + spaceRun(rest, 2)
			}
		}
	}
	if it == nil {
		return nil
	}

	it.MarkerCol = indent
	col := indent + consumed
	if it.MarkerType == "bullet" {
		text := line[col:]
		if mark, n, ok := matchCheckbox(text); ok {
			it.Mark, it.MarkCol = mark, intp(col)
			col += n
		} else if key, kn, ok := matchKey(text); ok {
			it.Key, it.KeyCol = key, intp(col)
			after := col + kn
			if mark2, n2, ok := matchCheckbox(line[after:]); ok {
				it.Mark, it.MarkCol = mark2, intp(after)
				col = after + n2
			}
		}
	}
	it.ContentCol = col
	return it
}

// =============================================================================
// Lines
// =============================================================================

// Line describes one line of a note. Optional fields are nil/empty when the
// Lua parser omits them.
type Line struct {
	Kind       string
	Indent     int
	ContentCol *int
	ContentEnd *int
	Section    bool
	Level      *int
	Heading    int
	Text       *string
	Names      []string
	Item       *Item
	Key        string
	KeyCol     *int
	KeyLen     int
	ID         string
	Separator  *bool
	Close      bool
	Lang       *string
	Inline     []Span // nil unless parsed with inline spans (and the line has content)
}

func isLabel(line string) bool {
	n := len(line)
	if n < 2 || line[n-1] != ':' {
		return false
	}
	prefix := line[:n-1]
	for i := 0; i < len(prefix); i++ {
		if prefix[i] == ':' {
			return false
		}
	}
	return !hasPeriodSpace(prefix)
}

// SectionText is the display text of a section line, attributes stripped.
func SectionText(line, kind string) string {
	switch kind {
	case KindHeading:
		i := 0
		for i < len(line) && line[i] == '#' {
			i++
		}
		if i > 0 {
			j := i + spaceRun(line, i)
			if j > i && j < len(line) {
				return StripAttributes(line[j:])
			}
		}
		return StripAttributes(line[i:])
	case KindBoldHeading:
		if k := boldHeadingColon(line); k > 0 {
			return StripAttributes(line[2:k])
		}
		return StripAttributes(line)
	case KindLabel:
		if len(line) > 0 && line[len(line)-1] == ':' {
			start := spaceRun(line, 0)
			if start <= len(line)-1 {
				return StripAttributes(line[start : len(line)-1])
			}
		}
		return StripAttributes(line)
	}
	return Trim(line)
}

// boldHeadingColon: for a bold heading "**Title:**" (^%*%*([^*]+):%*%*%s*$)
// the index of its colon, else 0.
func boldHeadingColon(line string) int {
	if len(line) < 6 || line[0] != '*' || line[1] != '*' {
		return 0
	}
	k := 2
	for k < len(line) && line[k] != '*' {
		k++
	}
	// at least one character of text, then ":**", then only spaces
	if k < 4 || line[k-1] != ':' || at(line, k) != '*' || at(line, k+1) != '*' {
		return 0
	}
	r := k + 2
	if spaceRun(line, r) != len(line)-r {
		return 0
	}
	return k - 1
}

func countByte(s string, c byte) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			n++
		}
	}
	return n
}

// isTableSeparator: ^%s*|[|%-:%s]*|%s*$ and the line contains "-".
func isTableSeparator(line string) bool {
	i := spaceRun(line, 0)
	if at(line, i) != '|' {
		return false
	}
	rest := line[i+1:]
	for k := 0; k < len(rest); k++ {
		c := rest[k]
		if c != '|' && c != '-' && c != ':' && !isSpace(c) {
			return false
		}
	}
	t := rest
	for len(t) > 0 && isSpace(t[len(t)-1]) {
		t = t[:len(t)-1]
	}
	if len(t) == 0 || t[len(t)-1] != '|' {
		return false
	}
	return countByte(line, '-') > 0
}

// hasPeriodSpaceBeforeColon: line:find("%.%s.-:")
func hasPeriodSpaceBeforeColon(line string) bool {
	for i := 0; i+1 < len(line); i++ {
		if line[i] == '.' && isSpace(line[i+1]) {
			for k := i + 2; k < len(line); k++ {
				if line[k] == ':' {
					return true
				}
			}
		}
	}
	return false
}

// Classify describes a single line on its own (no header or fence context).
func Classify(line string) *Line {
	indent := spaceRun(line, 0)
	if !hasNonSpace(line) {
		return &Line{Kind: KindBlank, Indent: indent, ContentCol: intp(indent)}
	}

	// heading: ^(#+)%s+%S
	if hashes := countLeading(line, '#'); hashes > 0 {
		ws := spaceRun(line, hashes)
		if ws > 0 && hashes+ws < len(line) {
			return &Line{
				Kind:       KindHeading,
				Section:    true,
				Heading:    hashes,
				Level:      intp(headingLevel(hashes)),
				Text:       strp(SectionText(line, KindHeading)),
				Indent:     0,
				ContentCol: intp(hashes + ws),
			}
		}
	}

	if len(line) >= 2 && line[0] == '@' && line[1] == '@' {
		return &Line{Kind: KindArticle, Indent: 0, ContentCol: intp(2), Text: strp(Trim(line[2:]))}
	}
	if isTagLine(line) {
		return &Line{Kind: KindTag, Indent: 0, ContentCol: intp(1)}
	}

	if colon := boldHeadingColon(line); colon > 0 {
		end := colon // inline content stops before ":**"
		return &Line{
			Kind:       KindBoldHeading,
			Section:    true,
			Level:      intp(levelBold),
			Text:       strp(SectionText(line, KindBoldHeading)),
			Indent:     0,
			ContentCol: intp(2),
			ContentEnd: intp(end),
		}
	}

	// footnote definition: ^%[%^([%w_.%-]+)%]:
	if len(line) > 3 && line[0] == '[' && line[1] == '^' {
		k := 2
		for k < len(line) && (isWordOrUnderscore(line[k]) || line[k] == '.' || line[k] == '-') {
			k++
		}
		if k > 2 && at(line, k) == ']' && at(line, k+1) == ':' {
			return &Line{Kind: KindFootnote, ID: line[2:k], Indent: 0, ContentCol: intp(k + 2 + spaceRun(line, k+2))}
		}
	}

	item := ItemOf(line)
	if isLabel(line) && !(item != nil && item.Mark != "") {
		src := line
		col := indent
		if item != nil {
			src = line[item.ContentCol:]
			col = item.ContentCol
		}
		return &Line{
			Kind:       KindLabel,
			Section:    true,
			Level:      intp(levelLabel + indent),
			Text:       strp(SectionText(src, KindLabel)),
			Indent:     indent,
			Item:       item,
			ContentCol: intp(col),
		}
	}

	if at(line, indent) == '|' {
		if countByte(line, '|') > 1 {
			return &Line{Kind: KindTable, Separator: boolp(isTableSeparator(line)), Indent: indent, ContentCol: intp(indent)}
		}
		return &Line{Kind: KindQuote, Indent: indent, ContentCol: intp(indent + 1)}
	}
	if at(line, indent) == '>' && isSpace(at(line, indent+1)) {
		return &Line{Kind: KindQuote, Indent: indent, ContentCol: intp(indent + 1 + spaceRun(line, indent+1))}
	}

	if item != nil {
		return &Line{Kind: KindItem, Indent: indent, Item: item, ContentCol: intp(item.ContentCol)}
	}

	d := &Line{Kind: KindText, Indent: indent, ContentCol: intp(indent)}
	if key, kn, ok := matchKey(line[indent:]); ok && !hasPeriodSpaceBeforeColon(line) {
		d.Key, d.KeyCol, d.KeyLen = key, intp(indent), kn
	}
	return d
}

func countLeading(s string, c byte) int {
	n := 0
	for n < len(s) && s[n] == c {
		n++
	}
	return n
}

// =============================================================================
// Documents
// =============================================================================

// fenceOf matches ^([ \t]*)(```+|~~~+)(.*)$: indent, fence and info string.
func fenceOf(line string) (string, string, string, bool) {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i++
	}
	c := at(line, i)
	if c != '`' && c != '~' {
		return "", "", "", false
	}
	n := countLeading(line[i:], c)
	if n < 3 {
		return "", "", "", false
	}
	return line[:i], line[i : i+n], line[i+n:], true
}

func isMathFence(line string) bool {
	i := spaceRun(line, 0)
	if at(line, i) != '$' || at(line, i+1) != '$' {
		return false
	}
	return spaceRun(line, i+2) == len(line)-(i+2)
}

func firstField(s string) string {
	s = Trim(s)
	for i := 0; i < len(s); i++ {
		if isSpace(s[i]) {
			return s[:i]
		}
	}
	return s
}

// Parse parses a whole note. With inline, every line with content also gets
// its inline spans.
func Parse(lines []string, inline bool) *AST {
	header := ParseHeader(lines, 0)
	out := &AST{Version: Version, Header: header, Lines: make([]*Line, 0, len(lines)), Sections: []*Section{}, Blocks: []*Block{}}
	if header.NameLnum > 0 {
		out.Sections = append(out.Sections, &Section{Lnum: header.NameLnum, Type: KindArticle, Level: 0, Text: header.Names[0], Names: header.Names})
	}

	type openCode struct {
		char  byte
		len   int
		block *Block
	}
	var code *openCode
	var mathBlock, tableBlock *Block

	for i, line := range lines {
		lnum := i + 1
		var d *Line
		switch {
		case code != nil:
			_, fence, info, ok := fenceOf(line)
			if ok && fence[0] == code.char && len(fence) >= code.len && !hasNonSpace(info) {
				d = &Line{Kind: KindFence, Indent: spaceRun(line, 0), Close: true}
				code.block.Finish = lnum
				code = nil
			} else {
				d = &Line{Kind: KindCode, Indent: spaceRun(line, 0)}
			}
		case mathBlock != nil:
			if isMathFence(line) {
				d = &Line{Kind: KindMathFence, Indent: spaceRun(line, 0), Close: true}
				mathBlock.Finish = lnum
				mathBlock = nil
			} else {
				d = &Line{Kind: KindMath, Indent: spaceRun(line, 0)}
			}
		case lnum <= header.LastLnum:
			switch {
			case len(line) >= 2 && line[0] == '@' && line[1] == '@':
				d = &Line{Kind: KindArticle, Indent: 0, ContentCol: intp(2), Text: strp(Trim(line[2:]))}
				if lnum == header.NameLnum {
					d.Section, d.Level, d.Names = true, intp(0), header.Names
				}
			case hasNonSpace(line):
				d = &Line{Kind: KindTag, Indent: 0, ContentCol: intp(1)}
			default:
				d = &Line{Kind: KindBlank, Indent: 0, ContentCol: intp(0)}
			}
		default:
			if indent, fence, info, ok := fenceOf(line); ok {
				lang := firstField(info)
				block := &Block{Kind: "code", Start: lnum, Finish: len(lines), Lang: strp(lang)}
				out.Blocks = append(out.Blocks, block)
				code = &openCode{char: fence[0], len: len(fence), block: block}
				d = &Line{Kind: KindFence, Indent: len(indent), Lang: strp(lang)}
			} else if isMathFence(line) {
				mathBlock = &Block{Kind: "math", Start: lnum, Finish: len(lines)}
				out.Blocks = append(out.Blocks, mathBlock)
				d = &Line{Kind: KindMathFence, Indent: spaceRun(line, 0)}
			} else {
				d = Classify(line)
				if d.Kind == KindArticle {
					d.Text = nil // "@@Name" outside the header is not an article
				} else if d.Section {
					out.Sections = append(out.Sections, &Section{Lnum: lnum, Type: d.Kind, Level: *d.Level, Text: *d.Text})
				}
			}
		}

		if d.Kind == KindTable {
			if tableBlock == nil {
				tableBlock = &Block{Kind: "table", Start: lnum, Finish: lnum}
				out.Blocks = append(out.Blocks, tableBlock)
			}
			tableBlock.Finish = lnum
		} else {
			tableBlock = nil
		}

		if inline && d.ContentCol != nil {
			to := len(line)
			if d.ContentEnd != nil {
				to = *d.ContentEnd
			}
			d.Inline = Inline(line, *d.ContentCol, to)
			if d.Inline == nil {
				d.Inline = []Span{}
			}
		}
		out.Lines = append(out.Lines, d)
	}
	return out
}
