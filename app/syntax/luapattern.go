package syntax

import (
	"fmt"
	"regexp"
	"strings"
)

// Lua pattern classes (%a, %d, …) as POSIX classes; Lua reads them in the C
// locale, ASCII only, and so do RE2's.
var luaClasses = map[byte]string{
	'a': "alpha", 'c': "cntrl", 'd': "digit", 'g': "graph", 'l': "lower",
	'p': "punct", 's': "space", 'u': "upper", 'w': "alnum", 'x': "xdigit",
}

// luaClass: the POSIX class for %c (uppercase: its complement), for use
// inside brackets, or "".
func luaClass(c byte) string {
	lower := c | 0x20
	name, ok := luaClasses[lower]
	if !ok {
		return ""
	}
	if c != lower {
		return "[:^" + name + ":]"
	}
	return "[:" + name + ":]"
}

// setByte: a literal byte inside brackets.
func setByte(c byte) string {
	switch c {
	case '\\', ']', '[', '^', '-':
		return `\` + string(c)
	}
	return regexp.QuoteMeta(string(c))
}

// LuaPatternRegexp translates a Lua pattern (what string.find takes, as in
// Neovim's syntax.label_pattern) to an RE2 regexp that matches the same
// strings when searched unanchored. %b, %f and back-references (%1) have no
// RE2 equivalent and are errors.
func LuaPatternRegexp(p string) (*regexp.Regexp, error) {
	var b strings.Builder
	b.WriteString("(?s)")
	i := 0
	if strings.HasPrefix(p, "^") {
		b.WriteByte('^')
		i = 1
	}
	depth := 0
	for i < len(p) {
		c := p[i]
		var item string
		switch {
		case c == '(':
			b.WriteByte('(')
			depth++
			i++
			continue
		case c == ')':
			if depth == 0 {
				return nil, fmt.Errorf("invalid pattern capture")
			}
			b.WriteByte(')')
			depth--
			i++
			continue
		case c == '$' && i == len(p)-1:
			b.WriteByte('$')
			i++
			continue
		case c == '%':
			if i+1 >= len(p) {
				return nil, fmt.Errorf("malformed pattern (ends with '%%')")
			}
			n := p[i+1]
			switch {
			case n == 'b' || n == 'f' || isDigit(n):
				return nil, fmt.Errorf("%%%c is not supported here", n)
			case luaClass(n) != "":
				item = "[" + luaClass(n) + "]"
			default:
				item = regexp.QuoteMeta(string(n))
			}
			i += 2
		case c == '[':
			set, end, err := luaSet(p, i)
			if err != nil {
				return nil, err
			}
			item = set
			i = end
		case c == '.':
			item = "."
			i++
		default:
			item = regexp.QuoteMeta(string(c))
			i++
		}
		if i < len(p) {
			switch p[i] {
			case '*', '+', '?':
				item += string(p[i])
				i++
			case '-':
				item += "*?"
				i++
			}
		}
		b.WriteString(item)
	}
	if depth != 0 {
		return nil, fmt.Errorf("unfinished capture")
	}
	return regexp.Compile(b.String())
}

// luaSet translates the set "[...]" starting at p[i]: the RE2 class and
// the index after its "]".
func luaSet(p string, i int) (string, int, error) {
	var b strings.Builder
	b.WriteByte('[')
	j := i + 1
	if at(p, j) == '^' {
		b.WriteByte('^')
		j++
	}
	first := true
	for {
		if j >= len(p) {
			return "", 0, fmt.Errorf("malformed pattern (missing ']')")
		}
		c := p[j]
		if c == ']' && !first {
			b.WriteByte(']')
			return b.String(), j + 1, nil
		}
		first = false
		switch {
		case c == '%':
			if j+1 >= len(p) {
				return "", 0, fmt.Errorf("malformed pattern (missing ']')")
			}
			if cls := luaClass(p[j+1]); cls != "" {
				b.WriteString(cls)
			} else {
				b.WriteString(setByte(p[j+1]))
			}
			j += 2
		case at(p, j+1) == '-' && j+2 < len(p) && p[j+2] != ']':
			b.WriteString(setByte(c) + "-" + setByte(p[j+2]))
			j += 3
		default:
			b.WriteString(setByte(c))
			j++
		}
	}
}
