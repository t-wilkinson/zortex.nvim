// Package edit changes single lines of a note the way the plugin's task
// commands do (lua/zortex/services/tasks.lua, edit_line): mark a task open
// or done (adding @done(today) and an @id), turn text into a task and back.
// tests/fixtures/edits.json, written by tests/gen_edits.lua from the Lua
// implementation, keeps the two in agreement.
package edit

import (
	"crypto/rand"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Ops
const (
	Open   = "open"   // a task, not done
	Done   = "done"   // a completed task with @done(today)
	Toggle = "toggle" // done <-> open; text becomes an open task
	Text   = "text"   // checkbox and @done removed
)

// ErrEmpty: an empty line can't become a task.
var ErrEmpty = errors.New("Empty line")

func attrPattern(key string, nonEmpty bool) *regexp.Regexp {
	val := `[^)]*`
	if nonEmpty {
		val = `[^)]+`
	}
	return regexp.MustCompile(`@` + regexp.QuoteMeta(key) + `\((` + val + `)\)`)
}

// Attribute returns the value of @key(value), as Lua's extract_attribute.
func Attribute(line, key string) (string, bool) {
	m := attrPattern(key, true).FindStringSubmatch(line)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// UpdateAttribute replaces the first @key(value) or appends " @key(value)".
func UpdateAttribute(line, key, value string) string {
	re := attrPattern(key, true)
	repl := "@" + key + "(" + value + ")"
	if loc := re.FindStringIndex(line); loc != nil {
		return line[:loc[0]] + repl + line[loc[1]:]
	}
	if line != "" && isLuaSpace(line[len(line)-1]) {
		return line + repl
	}
	return line + " " + repl
}

// AddAttribute adds @key(value) unless the line already has one.
func AddAttribute(line, key, value string) string {
	if _, ok := Attribute(line, key); ok {
		return line
	}
	return UpdateAttribute(line, key, value)
}

// RemoveAttribute removes every @key(...) and the whitespace before it.
func RemoveAttribute(line, key string) string {
	k := regexp.QuoteMeta(key)
	line = regexp.MustCompile(`[ \t\n\v\f\r]+@`+k+`\([^)]*\)`).ReplaceAllString(line, "")
	return regexp.MustCompile(`@`+k+`\([^)]*\)`).ReplaceAllString(line, "")
}

// isLuaSpace: Lua's %s.
func isLuaSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

func trimLuaSpace(s string) string {
	start, end := 0, len(s)
	for start < end && isLuaSpace(s[start]) {
		start++
	}
	for end > start && isLuaSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

// task: the line's checkbox (index of "[", the mark) when it is a task.
func task(line string) (markCol int, mark string, ok bool) {
	it := syntax.ItemOf(line)
	if it == nil || it.Mark == "" || it.MarkCol == nil {
		return 0, "", false
	}
	return *it.MarkCol, it.Mark, true
}

func completed(mark string) bool { return mark == "x" || mark == "X" }

func withMark(line string, markCol int, mark string) string {
	i := markCol + 1
	return line[:i] + mark + line[i+1:]
}

func setDone(line string, done bool, today string) string {
	col, _, _ := task(line)
	if done {
		return UpdateAttribute(withMark(line, col, "x"), "done", today)
	}
	return RemoveAttribute(withMark(line, col, " "), "done")
}

// ConvertToTask: "- text" -> "- [ ] text @id(id)", and a timed line keeps
// its time in front: "16:00 Report" -> "16:00 [ ] Report @id(id)" (as
// convert_line_to_task).
func ConvertToTask(line, id string) (string, error) {
	if strings.TrimLeft(line, " \t\n\v\f\r") == "" {
		return "", ErrEmpty
	}
	if it := syntax.ItemOf(line); it != nil && it.MarkerType == "time" && it.Mark == "" {
		return AddAttribute(line[:it.ContentCol]+"[ ] "+trimLuaSpace(line[it.ContentCol:]), "id", id), nil
	}
	n := 0
	for n < len(line) && isLuaSpace(line[n]) {
		n++
	}
	indent := line[:n]
	content := trimLuaSpace(line[n:])
	text := content
	if content != "" && content[0] == '-' {
		rest := content[1:]
		j := 0
		for j < len(rest) && isLuaSpace(rest[j]) {
			j++
		}
		if j < len(rest) {
			text = rest[j:]
		}
	}
	return AddAttribute(indent+"- [ ] "+text, "id", id), nil
}

// Line applies op to line. today is "YYYY-MM-DD"; newID makes an @id when
// the task needs one.
func Line(line, op, today string, newID func() string) (string, error) {
	col, mark, isTask := task(line)
	if op == Text {
		if !isTask {
			return line, nil
		}
		before, after := line[:col], line[col+3:]
		after = strings.TrimPrefix(after, " ")
		// "16:00 - [ ] Task" -> "16:00 Task": the dash goes with the box
		if it := syntax.ItemOf(line); it != nil && it.MarkerType == "time" {
			if t := strings.TrimRight(before, " \t"); strings.HasSuffix(t, "-") && len(t) > it.MarkerCol+len(it.Marker) {
				before = strings.TrimRight(t[:len(t)-1], " \t") + " "
			}
		}
		return RemoveAttribute(before+after, "done"), nil
	}
	if op != Open && op != Done && op != Toggle {
		return "", fmt.Errorf("unknown edit: %s", op)
	}
	if !isTask {
		converted, err := ConvertToTask(line, newID())
		if err != nil {
			return "", err
		}
		if op == Done {
			return setDone(converted, true, today), nil
		}
		return converted, nil
	}
	if _, ok := Attribute(line, "id"); !ok {
		line = AddAttribute(line, "id", newID())
	}
	wantDone := op == Done
	if op == Toggle {
		wantDone = !completed(mark)
	}
	if wantDone == completed(mark) {
		return line, nil
	}
	return setDone(line, wantDone, today), nil
}

const idChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// NewID returns a random 5-character task id (the plugin's alphabet).
func NewID() string {
	var b [5]byte
	_, _ = rand.Read(b[:])
	for i := range b {
		b[i] = idChars[int(b[i])%len(idChars)]
	}
	return string(b[:])
}
