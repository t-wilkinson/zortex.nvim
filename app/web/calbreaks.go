package web

import (
	"fmt"
	"sort"
)

// Short breaks inside a longer block, as Neovim's services/calendar_breaks
// (checked against tests/fixtures/calendar.json, "resumes"). A timed line
// with an end ("12:00 Break @15m", "12:00 - 12:15 Break") that starts while
// an earlier block is still on interrupts it, and the block resumes when it
// ends, until the next timed line starts (or its own end). Flat, the block
// is the latest earlier line still running; nested, the line it is under.
// An @event without an end is a moment, not a block; a done or carried
// task isn't resumed.

// calResume: a break (After) handing its block back from From to To ("":
// until the next thing).
type calResume struct {
	Block, After int // indexes into the day's own entries
	From, To     string
}

type breakRow struct {
	i           int
	depth       int
	start, stop int // minutes; stop -1: no end
	event       bool
	closed      bool
}

// calResumes: the breaks among a day's own entries (file order, with Depth).
func calResumes(entries []calEntry) []calResume {
	rows := make([]*breakRow, 0, len(entries))
	for i, e := range entries {
		r := &breakRow{i: i, depth: e.Depth, start: -1, stop: -1, event: e.Event, closed: e.Done || e.Moved}
		if _, m, ok := clock(e.Time); ok {
			r.start = m
			if _, s, ok := clock(e.End); ok && s > m {
				r.stop = s
			}
		}
		rows = append(rows, r)
	}
	var timed []*breakRow
	for _, r := range rows {
		if r.start >= 0 {
			timed = append(timed, r)
		}
	}
	parent := map[*breakRow]*breakRow{}
	var stack []*breakRow
	for _, r := range rows {
		for len(stack) > 0 && stack[len(stack)-1].depth >= r.depth {
			stack = stack[:len(stack)-1]
		}
		if len(stack) > 0 {
			if up := stack[len(stack)-1]; r.start >= 0 && up.start >= 0 {
				parent[r] = up
			}
		}
		stack = append(stack, r)
	}
	canHold := func(b *breakRow) bool { return !(b.event && b.stop < 0) }
	runsOver := func(b, e *breakRow) bool { return b.stop < 0 || (b.stop > e.start && b.stop >= e.stop) }
	interrupts := map[*breakRow]*breakRow{}
	var top []*breakRow
	for _, r := range timed {
		if parent[r] == nil {
			top = append(top, r)
		}
	}
	sort.SliceStable(top, func(a, b int) bool {
		if top[a].start != top[b].start {
			return top[a].start < top[b].start
		}
		return top[a].i < top[b].i
	})
	var bg *breakRow
	for _, e := range top {
		if e.stop >= 0 && bg != nil && bg.start < e.start && runsOver(bg, e) {
			interrupts[e] = bg
		} else if canHold(e) {
			bg = e
		}
	}
	for _, e := range timed {
		if p := parent[e]; p != nil && e.stop >= 0 && e.start >= p.start && runsOver(p, e) {
			interrupts[e] = p
		}
	}
	var out []calResume
	for _, e := range timed {
		b := interrupts[e]
		if b == nil || b.closed || !canHold(b) {
			continue
		}
		to := b.stop
		for _, x := range timed {
			if x != e && x != b && parent[x] != e && x.start > e.start && (to < 0 || x.start < to) {
				to = x.start
			}
		}
		if to < 0 || to > e.stop {
			r := calResume{Block: b.i, After: e.i, From: hhmm(e.stop)}
			if to >= 0 {
				r.To = hhmm(to)
			}
			out = append(out, r)
		}
	}
	return out
}

func hhmm(m int) string { return fmt.Sprintf("%02d:%02d", m/60, m%60) }

// withResumes: the day's rows with a resume row after each break, once the
// rows nested under it are done (a break inside a break's block resumes
// first): the block again, from the break's end.
func withResumes(rows []calEntry, own []calEntry, res []calResume) []calEntry {
	if len(res) == 0 {
		return rows
	}
	byAfter := map[int]calResume{}
	for _, r := range res {
		byAfter[own[r.After].Lnum] = r
	}
	type pending struct {
		depth int
		row   calEntry
	}
	var stack []pending
	var out []calEntry
	flush := func(depth int) {
		for len(stack) > 0 && stack[len(stack)-1].depth >= depth {
			out = append(out, stack[len(stack)-1].row)
			stack = stack[:len(stack)-1]
		}
	}
	for _, row := range rows {
		flush(row.Depth)
		out = append(out, row)
		if row.Virtual || row.Feed != "" || row.Repeat {
			continue
		}
		if r, ok := byAfter[row.Lnum]; ok {
			b := own[r.Block]
			stack = append(stack, pending{row.Depth, calEntry{Lnum: b.Lnum, Time: r.From, End: r.To, Text: b.Text, HTML: b.HTML, Depth: row.Depth, URL: b.URL, Resume: true}})
		}
	}
	flush(-1)
	return out
}
