package edit

import (
	"math"
	"sort"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// CalendarSize is the size a just-completed calendar task gets from its
// block, or "": the task at lnum (1-based, no size of its own) must be a
// timed task with no tasks under it ("16:00 [ ] Task"), or the only task
// nested under a timed line, and the block lasts its own range
// ("16:00 - 17:30") or until the next timed line of the day at its indent.
// The size is the one whose hours are closest by ratio, the larger on a
// tie. As the plugin's services/tasks.calendar_size, checked by
// tests/fixtures/autosize.json.
func CalendarSize(lines []string, lnum int, sizes map[string]float64) string {
	if lnum < 1 || lnum > len(lines) {
		return ""
	}
	line := lines[lnum-1]
	if _, mark, ok := task(line); !ok || !completed(mark) || sizeOf(line) != "" {
		return ""
	}
	timed := func(l string) *syntax.Item {
		if syntax.Classify(l).Kind != syntax.KindItem {
			return nil
		}
		if it := syntax.ItemOf(l); it != nil && it.MarkerType == "time" && it.Time != nil {
			return it
		}
		return nil
	}
	// the timed line it is, or is nested under
	own, head := indentOf(line), 0
	if timed(line) != nil {
		head = lnum // "16:00 [ ] Task": its own block
	}
	for l := lnum - 1; l >= 1 && head == 0; l-- {
		text := lines[l-1]
		if blankLine(text) {
			continue
		}
		if indentOf(text) < own {
			if timed(text) != nil {
				head = l
			}
			break
		}
		if dateLine.MatchString(text) {
			break
		}
	}
	if head == 0 {
		return ""
	}
	base := indentOf(lines[head-1])
	tm := timed(lines[head-1]).Time
	// exactly one task in the block
	count, after := 0, len(lines)+1
	for l := head + 1; l <= len(lines); l++ {
		text := lines[l-1]
		if blankLine(text) {
			continue
		}
		if indentOf(text) <= base || dateLine.MatchString(text) {
			after = l
			break
		}
		if syntax.Classify(text).Kind == syntax.KindItem {
			if it := syntax.ItemOf(text); it != nil && it.Mark != "" {
				count++
			}
		}
	}
	// exactly one task: itself (a timed task with tasks under it is a group)
	want := 1
	if head == lnum {
		want = 0
	}
	if count != want {
		return ""
	}
	// its length
	from := tm.From
	if from == "" {
		from = tm.At
	}
	start, ok := hm(from)
	if !ok {
		return ""
	}
	stop, ok := hm(tm.To)
	if !ok {
		for l := after; l <= len(lines); l++ {
			text := lines[l-1]
			if dateLine.MatchString(text) {
				break
			}
			if blankLine(text) || indentOf(text) != base {
				continue
			}
			if it := timed(text); it != nil {
				next := it.Time.From
				if next == "" {
					next = it.Time.At
				}
				stop, ok = hm(next)
				break
			}
		}
	}
	if !ok || stop <= start {
		return ""
	}
	hours := float64(stop-start) / 60
	names := make([]string, 0, len(sizes))
	for n := range sizes {
		names = append(names, n)
	}
	sort.Strings(names)
	best, bestD, bestH := "", 0.0, 0.0
	for _, n := range names {
		h := sizes[n]
		if h <= 0 {
			continue
		}
		d := math.Abs(math.Log(h / hours))
		if best == "" || d < bestD-1e-9 || (math.Abs(d-bestD) <= 1e-9 && h > bestH) {
			best, bestD, bestH = n, d, h
		}
	}
	return best
}

// hm: "16:05" -> minutes since midnight.
func hm(s string) (int, bool) {
	if len(s) < 4 || len(s) > 5 || s[len(s)-3] != ':' {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if i == len(s)-3 {
			continue
		}
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	h, m := n/100, n%100
	return h*60 + m, true
}
