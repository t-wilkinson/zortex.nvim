package syntax

import "strings"

// Character classes, matching Lua patterns in the C locale (byte-wise, ASCII):
// %s, %d, %a, %w. Bytes >= 0x80 belong to none of them.

func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\v' || b == '\f' || b == '\r'
}

func isDigit(b byte) bool { return b >= '0' && b <= '9' }

func isAlpha(b byte) bool { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') }

func isAlnum(b byte) bool { return isDigit(b) || isAlpha(b) }

// at returns s[i] or 0 when i is out of range.
func at(s string, i int) byte {
	if i < 0 || i >= len(s) {
		return 0
	}
	return s[i]
}

// spaceRun counts whitespace bytes from i.
func spaceRun(s string, i int) int {
	n := 0
	for i+n < len(s) && isSpace(s[i+n]) {
		n++
	}
	return n
}

// Trim removes leading and trailing whitespace (Lua "^%s*(.-)%s*$").
func Trim(s string) string {
	start, end := 0, len(s)
	for start < end && isSpace(s[start]) {
		start++
	}
	for end > start && isSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

func hasNonSpace(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isSpace(s[i]) {
			return true
		}
	}
	return false
}

// hasPeriodSpace reports whether s contains ". " (a period followed by whitespace).
func hasPeriodSpace(s string) bool {
	for i := 0; i+1 < len(s); i++ {
		if s[i] == '.' && isSpace(s[i+1]) {
			return true
		}
	}
	return false
}

// timeAt matches %d%d?:%d%d at i and returns the end index, or -1.
func timeAt(s string, i int) int {
	if !isDigit(at(s, i)) {
		return -1
	}
	colon := -1
	if isDigit(at(s, i+1)) && at(s, i+2) == ':' {
		colon = i + 2
	} else if at(s, i+1) == ':' {
		colon = i + 1
	}
	if colon < 0 || !isDigit(at(s, colon+1)) || !isDigit(at(s, colon+2)) {
		return -1
	}
	return colon + 3
}

// SplitLines splits file content the way Vim's readfile() does: a final
// newline does not add an empty line, a CR before each newline is dropped and
// a UTF-8 BOM is removed.
func SplitLines(content string) []string {
	content = strings.TrimPrefix(content, "\xef\xbb\xbf")
	if content == "" {
		return []string{}
	}
	content = strings.TrimSuffix(content, "\n")
	lines := strings.Split(content, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

// Lower lowercases ASCII letters only, like Lua's string.lower in the C locale.
func Lower(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] >= 'A' && s[i] <= 'Z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return s
}

// ListHas reports whether list contains value, ignoring ASCII case.
func ListHas(list []string, value string) bool {
	v := Lower(value)
	for _, x := range list {
		if Lower(x) == v {
			return true
		}
	}
	return false
}
