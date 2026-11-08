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

import (
	"regexp"
	"sync/atomic"
)

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
	KindRule        = "rule"
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
	Label      bool   `json:"label,omitempty"` // the key reads as a label ("Key::", or "Key:" by the label rule)
	Mark       string `json:"mark,omitempty"`  // checkbox character
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

// matchKey matches "Key:: rest" or "Key: rest" at the start of text, or a
// key ending it ("Key::", "Key:"): the key, the length consumed including
// the colons and the whitespace after, and the number of colons (1 or 2).
// Text must follow after a space, so "14:00", "https://…" and "a::b" have
// no key. "Key::" keys are any text without a colon; "Key:" keys start with
// a word character, have no sentence (". ") and don't end in "*".
func matchKey(text string) (string, int, int, bool) {
	colon := -1
	for i := 0; i < len(text); i++ {
		if text[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 1 || isSpace(text[0]) {
		return "", 0, 0, false
	}
	key := text[:colon]
	colons := 1
	if at(text, colon+1) == ':' {
		colons = 2
	} else if !isAlnum(text[0]) || hasPeriodSpace(key) || key[len(key)-1] == '*' || len(key) > 60 {
		return "", 0, 0, false
	}
	if isSpace(key[len(key)-1]) || StripAttributes(key) == "" {
		return "", 0, 0, false
	}
	ws := spaceRun(text, colon+colons)
	n := colon + colons + ws
	if n < len(text) && ws == 0 {
		return "", 0, 0, false
	}
	return key, n, colons, true
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
	case len(rest) >= 2 && rest[0] == '-' && isSpace(rest[1]):
		it = &Item{Marker: "-", MarkerType: "bullet"}
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
		} else if key, kn, colons, ok := matchKey(text); ok {
			it.Key, it.KeyCol = key, intp(col)
			it.Label = colons == 2 || SoftLabel(key)
			after := col + kn
			if mark2, n2, ok := matchCheckbox(line[after:]); ok {
				it.Mark, it.MarkCol = mark2, intp(after)
				col = after + n2
			}
		}
	} else if it.MarkerType == "time" {
		// a timed task: "16:00 [ ] Task", "16:00 - 17:00 [ ] Task"
		if mark, n, ok := matchCheckbox(line[col:]); ok {
			it.Mark, it.MarkCol = mark, intp(col)
			col += n
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

// The label rule for "Key:" lines (one colon), Neovim's
// syntax.label_max_words and syntax.label_pattern, which it writes to the
// notes folder's .z/syntax.json (SetLabelRule). "Key::" is always a label.

// DefaultMaxLabelWords: a "Key:" is a label up to this many words
// (attributes not counted).
const DefaultMaxLabelWords = 3

var (
	maxLabelWords atomic.Int32
	labelPattern  atomic.Pointer[labelRule]
)

type labelRule struct {
	src string
	re  *regexp.Regexp
}

func init() { maxLabelWords.Store(DefaultMaxLabelWords) }

// MaxLabelWords is how many words a "Key:" label may have (0: the count is off).
func MaxLabelWords() int { return int(maxLabelWords.Load()) }

// LabelPattern is the Lua pattern in use ("" for none).
func LabelPattern() string {
	if r := labelPattern.Load(); r != nil {
		return r.src
	}
	return ""
}

// SetLabelRule changes the label rule: up to `words` words (< 0: the
// default, 0: off) or matching the Lua `pattern` ("": none). It reports
// whether the rule changed; notes parsed before keep their old reading:
// reparse them. A pattern that can't be translated is an error and is off.
func SetLabelRule(words int, pattern string) (bool, error) {
	if words < 0 {
		words = DefaultMaxLabelWords
	}
	changed := maxLabelWords.Swap(int32(words)) != int32(words)
	var rule *labelRule
	var err error
	if pattern != "" {
		var re *regexp.Regexp
		if re, err = LuaPatternRegexp(pattern); err == nil {
			rule = &labelRule{src: pattern, re: re}
		}
	}
	if old := labelPattern.Swap(rule); (old == nil) != (rule == nil) || (old != nil && old.src != rule.src) {
		changed = true
	}
	return changed, err
}

// SoftLabel: does "key:" (one colon) read as a label? It does when, with
// attributes stripped, it has at most MaxLabelWords words or matches the
// label pattern (core/syntax.soft_label).
func SoftLabel(key string) bool {
	text := StripAttributes(key)
	if text == "" {
		return false
	}
	if r := labelPattern.Load(); r != nil && r.re.MatchString(text) {
		return true
	}
	n := MaxLabelWords()
	return n > 0 && wordCount(text) <= n
}

// wordCount: runs of non-space bytes (Lua's %S+).
func wordCount(s string) int {
	n, in := 0, false
	for i := 0; i < len(s); i++ {
		if isSpace(s[i]) {
			in = false
		} else if !in {
			in = true
			n++
		}
	}
	return n
}

// colonRun: a whole line "Text::" or "Text:::" (whitespace may follow,
// ^(%s*)(.-[^%s:])(:+)%s*$): the end of its text and its number of colons
// (2 or 3), else 0. The text ends in neither a space nor a colon.
func colonRun(line string) (int, int) {
	end := len(line)
	for end > 0 && isSpace(line[end-1]) {
		end--
	}
	k := end
	for k > 0 && line[k-1] == ':' {
		k--
	}
	colons := end - k
	start := spaceRun(line, 0)
	if (colons != 2 && colons != 3) || k <= start || isSpace(line[k-1]) || StripAttributes(line[start:k]) == "" {
		return 0, 0
	}
	return k, colons
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
	case KindBoldHeading, KindLabel:
		// the text before the colons (^%s*(.-[^%s:]):+%s*$)
		end := len(line)
		for end > 0 && isSpace(line[end-1]) {
			end--
		}
		k := end
		for k > 0 && line[k-1] == ':' {
			k--
		}
		start := spaceRun(line, 0)
		if k < end && k > start && !isSpace(line[k-1]) {
			return StripAttributes(line[start:k])
		}
		return StripAttributes(Trim(line))
	}
	return Trim(line)
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

	// "---": a rule, a separator (a slide break in a deck)
	if isRule(line) {
		return &Line{Kind: KindRule, Indent: 0, ContentCol: intp(0)}
	}

	// "[^1]: text", "[^Smith, 2020] text", or the id alone on its line
	if k, ok := footnoteID(line, 0); ok {
		switch {
		case at(line, k+1) == ':':
			return &Line{Kind: KindFootnote, ID: line[2:k], Indent: 0, ContentCol: intp(k + 2 + spaceRun(line, k+2))}
		case k+1 == len(line) || isSpace(line[k+1]):
			return &Line{Kind: KindFootnote, ID: line[2:k], Indent: 0, ContentCol: intp(k + 1 + spaceRun(line, k+1))}
		}
	}

	if at(line, indent) == '|' && countByte(line, '|') > 1 {
		return &Line{Kind: KindTable, Separator: boolp(isTableSeparator(line)), Indent: indent, ContentCol: intp(indent)}
	}
	if at(line, indent) == '>' && isSpace(at(line, indent+1)) {
		return &Line{Kind: KindQuote, Indent: indent, ContentCol: intp(indent + 1 + spaceRun(line, indent+1))}
	}

	if item := ItemOf(line); item != nil {
		return &Line{Kind: KindItem, Indent: indent, Item: item, ContentCol: intp(item.ContentCol)}
	}

	// "Title:::" (unindented): a bold heading; "Label::": a label, nested
	// by its indent. Inline content stops before the colons.
	if textEnd, colons := colonRun(line); colons == 3 && indent == 0 {
		return &Line{
			Kind:       KindBoldHeading,
			Section:    true,
			Level:      intp(levelBold),
			Text:       strp(SectionText(line, KindBoldHeading)),
			Indent:     0,
			ContentCol: intp(0),
			ContentEnd: intp(textEnd),
		}
	} else if colons == 2 {
		return &Line{
			Kind:       KindLabel,
			Section:    true,
			Level:      intp(levelLabel + indent),
			Text:       strp(SectionText(line, KindLabel)),
			Indent:     indent,
			ContentCol: intp(indent),
			ContentEnd: intp(textEnd),
		}
	}

	// "Label:: text", or "Label: text" / "Label:" by the label rule
	d := &Line{Kind: KindText, Indent: indent, ContentCol: intp(indent)}
	if key, kn, colons, ok := matchKey(line[indent:]); ok && (colons == 2 || (SoftLabel(key) && !hasPeriodSpaceBeforeColon(line))) {
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
func Parse(lines []string, inline bool) *AST { return ParseWith(lines, inline, nil) }

// ParseWith is Parse with the header given instead of read (a Markdown
// document's, notes.MarkdownLines: its names, the article on line 1), as
// core/syntax.parse's opts.header; nil reads it.
func ParseWith(lines []string, inline bool, given *Header) *AST {
	var header Header
	if given != nil {
		header = *given
	} else {
		header = ParseHeader(lines, 0)
	}
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

// isRule: "---" (three or more dashes from the first column, trailing
// whitespace allowed), as the plugin's "^%-%-%-+%s*$".
func isRule(line string) bool {
	i := 0
	for i < len(line) && line[i] == '-' {
		i++
	}
	if i < 3 {
		return false
	}
	for ; i < len(line); i++ {
		if !isSpace(line[i]) {
			return false
		}
	}
	return true
}
