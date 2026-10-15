package edit

import (
	"regexp"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Moved is the checkbox of a task carried to a later day ("- [>] ..."):
// neither open nor done.
const Moved = ">"

// LineEdit replaces line Lnum (1-based).
type LineEdit struct {
	Lnum int    `json:"lnum"`
	Line string `json:"line"`
}

// CarryPlan is what carrying open tasks forward changes in a calendar.
type CarryPlan struct {
	Edits []LineEdit // the carried tasks, marked [>] (with an @id)
	At    int        // insert Add before this line (0: nothing to add)
	Add   []string   // the copies (and a new day heading when today had none)
}

var (
	dateLine = regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2}):\s*$`)
	idAttr   = regexp.MustCompile(`@id\(([^)\s]+)\)`)
)

// ID is a line's @id, or "".
func ID(line string) string {
	if m := idAttr.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	return ""
}

func indentOf(line string) int {
	n := 0
	for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
		n++
	}
	return n
}

// Indent is the width of a line's leading spaces and tabs (bytes).
func Indent(line string) int { return indentOf(line) }

func blankLine(line string) bool { return strings.TrimSpace(line) == "" }

func isFence(line string) bool {
	t := strings.TrimSpace(line)
	return strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~")
}

// absoluteText is line lnum from byte `from` on, its parent-relative links
// ([./-Item]) written out in full where they resolve.
func absoluteText(lines []string, lnum, from int) string {
	line := lines[lnum-1]
	var b strings.Builder
	pos := from
	for _, sp := range links.LinksOn(line) {
		if sp.S >= from && links.IsParentRelative(sp.Definition) {
			if abs, err := links.Absolute(lines, lnum, sp.Definition); err == nil {
				b.WriteString(line[pos:sp.S])
				b.WriteString("[" + abs + "]")
				pos = sp.E
			}
		}
	}
	b.WriteString(line[pos:])
	return b.String()
}

func dayNumber(date string) int {
	t, err := time.Parse("2006-01-02", date)
	if err != nil {
		return 0
	}
	return int(t.Unix() / 86400)
}

// Carry plans carrying the open tasks of the days in [from, today) to today
// in a calendar's lines, as services/planner.carry in the plugin does
// (tests/fixtures/carry.json keeps the two in agreement):
//
//   - each carried task is marked [>], and gets an @id (newID) if it has none
//   - its copy, with the same @id, goes at the end of today (a new day is
//     placed next to its nearest neighbour in time)
//   - a task under a linked line that isn't a task ("09:00 [P/#1.4 - zortex]")
//     goes under a copy of that line ("- [P/#1.4 - zortex]"), its [./-Item]
//     links kept when that line is their parent; other tasks become
//     "- [ ] ..." with [./-Item] links written out
//   - repeating entries (@every, @repeat) stay; a task whose @id is already
//     on today is only marked
func Carry(lines []string, today, from string, newID func() string) CarryPlan {
	type block struct {
		date          string
		heading, last int
	}
	var blocks []*block
	fence := false
	for i, l := range lines {
		if isFence(l) {
			fence = !fence
		} else if !fence {
			if m := dateLine.FindStringSubmatch(l); m != nil {
				blocks = append(blocks, &block{date: m[1] + "-" + m[2] + "-" + m[3], heading: i + 1})
			}
		}
	}
	for i, b := range blocks {
		stop := len(lines)
		if i+1 < len(blocks) {
			stop = blocks[i+1].heading - 1
		}
		b.last = b.heading
		for l := b.heading + 1; l <= stop; l++ {
			if !blankLine(lines[l-1]) {
				b.last = l
			}
		}
	}
	var todayBlock *block
	for _, b := range blocks {
		if b.date == today && todayBlock == nil {
			todayBlock = b
		}
	}
	onToday := map[string]bool{}
	if todayBlock != nil {
		for l := todayBlock.heading + 1; l <= todayBlock.last; l++ {
			if id := ID(lines[l-1]); id != "" {
				onToday[id] = true
			}
		}
	}

	var plan CarryPlan
	groups := map[string][]string{}
	var order []string
	carried := map[string]bool{}
	for _, b := range blocks {
		if b.date < from || b.date >= today {
			continue
		}
		inFence := false
		for l := b.heading + 1; l <= b.last; l++ {
			line := lines[l-1]
			if isFence(line) {
				inFence = !inFence
				continue
			}
			if inFence {
				continue
			}
			it := syntax.ItemOf(line)
			if it == nil || it.Mark != " " || it.MarkCol == nil ||
				strings.Contains(line, "@every(") || strings.Contains(line, "@repeat(") {
				continue
			}
			// the nearest linked line above it that isn't a task (head), and
			// the nearest linked one (its ./ links' parent)
			head, parent := 0, 0
			want := indentOf(line)
			for k := l - 1; k >= b.heading+1; k-- {
				up := lines[k-1]
				if blankLine(up) || indentOf(up) >= want {
					continue
				}
				if len(links.LinksOn(up)) > 0 {
					if parent == 0 {
						parent = k
					}
					if upIt := syntax.ItemOf(up); upIt == nil || upIt.Mark == "" {
						head = k
						break
					}
				}
				want = indentOf(up)
				if want == 0 {
					break
				}
			}
			mc := *it.MarkCol
			id := ID(line)
			marked := line[:mc+1] + Moved + line[mc+2:]
			if id == "" {
				id = newID()
				marked = AddAttribute(marked, "id", id)
			}
			plan.Edits = append(plan.Edits, LineEdit{Lnum: l, Line: marked})
			if onToday[id] || carried[id] {
				continue
			}
			carried[id] = true
			var copyLine, key string
			if head > 0 {
				if parent == head {
					copyLine = "  - " + line[mc:]
				} else {
					copyLine = "  - " + absoluteText(lines, l, mc)
				}
				hcol := indentOf(lines[head-1])
				if hit := syntax.ItemOf(lines[head-1]); hit != nil {
					hcol = hit.ContentCol
				}
				key = "- " + absoluteText(lines, head, hcol)
			} else {
				copyLine = "- " + absoluteText(lines, l, mc)
			}
			copyLine = AddAttribute(copyLine, "id", id)
			if _, ok := groups[key]; !ok {
				order = append(order, key)
			}
			groups[key] = append(groups[key], copyLine)
		}
	}

	var out []string
	for _, key := range order {
		if key != "" {
			out = append(out, key)
		}
		out = append(out, groups[key]...)
	}
	if len(out) == 0 {
		return plan
	}
	if todayBlock != nil {
		plan.At, plan.Add = todayBlock.last+1, out
		return plan
	}
	// a new day, next to its nearest neighbour in time
	target := dayNumber(today)
	beforeI, afterI := -1, -1
	var beforeN, afterN int
	for i, b := range blocks {
		n := dayNumber(b.date)
		if n < target && (beforeI < 0 || n >= beforeN) {
			beforeI, beforeN = i, n
		} else if n > target && (afterI < 0 || n < afterN) {
			afterI, afterN = i, n
		}
	}
	at := len(lines) + 1
	if afterI >= 0 {
		if beforeI >= 0 && target-beforeN <= afterN-target {
			if beforeI+1 < len(blocks) {
				at = blocks[beforeI+1].heading
			}
		} else {
			at = blocks[afterI].heading
		}
	}
	add := append([]string{today + ":"}, out...)
	add = append(add, "")
	if at > len(lines) {
		at = len(lines) + 1
		if len(lines) > 0 && !blankLine(lines[len(lines)-1]) {
			add = append([]string{""}, add...)
		}
		add = add[:len(add)-1]
	} else if at > 1 && !blankLine(lines[at-2]) {
		add = append([]string{""}, add...)
	}
	plan.At, plan.Add = at, add
	return plan
}
