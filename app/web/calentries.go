package web

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// What an entry of the calendar is, as Neovim's calendar sees it
// (stores/calendar, services/calendar_entry): tests/fixtures/calendar.json,
// written by tests/gen_edits.lua, holds the plugin's reading of one
// calendar and calendar_test.go checks calendarEntries against it.

var (
	// "- 14:00 Dentist", "- 15:00 - 15:30 Standup": a time after the bullet
	bulletRange = regexp.MustCompile(`^(\d\d?:\d\d)\s*-\s*(\d\d?:\d\d)\s+`)
	bulletAt    = regexp.MustCompile(`^(\d\d?:\d\d)\s+`)
	durWords    = regexp.MustCompile(`(\d+\.?\d*)\s*([hdmw])`)
	bareDur     = regexp.MustCompile(`^\d+\.?\d*[hdmw]$`)
)

// clock: "7:05" -> "07:05" (minutes since midnight, ok).
func clock(hm string) (string, int, bool) {
	m, ok := clockMinutes(hm)
	if !ok || !strings.Contains(hm, ":") {
		return "", 0, false
	}
	return fmt.Sprintf("%02d:%02d", m/60, m%60), m, true
}

// durationMinutes: "90m", "1h30m", "2d" (as the plugin's parse_durations).
func durationMinutes(s string) float64 {
	total := 0.0
	for _, m := range durWords.FindAllStringSubmatch(strings.ToLower(s), -1) {
		n, _ := strconv.ParseFloat(m[1], 64)
		total += n * map[string]float64{"m": 1, "h": 60, "d": 1440, "w": 10080}[m[2]]
	}
	return total
}

// entryDuration: @dur(…), else @est(…), else a bare @2h, in minutes.
func entryDuration(spans []syntax.Span) float64 {
	var dur, est, bare float64
	for _, sp := range spans {
		if sp.Type != "attribute" {
			continue
		}
		key := syntax.Lower(sp.Key)
		switch {
		case key == "dur" && dur == 0:
			dur = durationMinutes(sp.Value)
		case key == "est" && est == 0:
			est = durationMinutes(sp.Value)
		case sp.Value == "" && bareDur.MatchString(key) && bare == 0:
			bare = durationMinutes(key)
		}
	}
	switch {
	case dur > 0:
		return dur
	case bare > 0:
		return bare
	}
	return est
}

// calendarEntries: the entries of doc's days in [from, to] ("" for no
// bound), each day's in file order with its depth (the rank of its indent
// among the day's indents). Only what the line says: no links resolved.
func calendarEntries(doc *notes.Document, from, to string) map[string][]calEntry {
	days := map[string][]calEntry{}
	indents := map[string][]int{}
	date := ""
	for i, line := range doc.Lines {
		lnum := i + 1
		if m := dateLabel.FindStringSubmatch(line); m != nil {
			date = m[1] + "-" + m[2] + "-" + m[3]
			continue
		}
		if date == "" || (from != "" && date < from) || (to != "" && date > to) || doc.InCode(lnum) {
			continue
		}
		if syntax.Classify(line).Kind != syntax.KindItem {
			continue
		}
		it := syntax.ItemOf(line)
		if it == nil {
			continue
		}
		spans := doc.Spans(lnum)
		col := it.ContentCol
		e := calEntry{
			Lnum: lnum,
			Task: it.Mark != "",
			Done: it.Mark == "x" || it.Mark == "X",
		}
		if it.Mark == edit.Moved {
			e.Moved = true
		}
		start, end := "", ""
		if it.Time != nil {
			start, end = it.Time.At, it.Time.To
			if start == "" {
				start = it.Time.From
			}
		} else if !e.Task {
			if m := bulletRange.FindStringSubmatch(line[col:]); m != nil {
				start, end, col = m[1], m[2], col+len(m[0])
			} else if m := bulletAt.FindStringSubmatch(line[col:]); m != nil {
				start, col = m[1], col+len(m[0])
			}
		}
		if t, startMin, ok := clock(start); ok {
			e.Time = t
			if t2, _, ok := clock(end); ok {
				e.End = t2
			} else if d := entryDuration(spans); d > 0 && end == "" {
				stop := (startMin + int(d)) % (24 * 60)
				e.End = fmt.Sprintf("%02d:%02d", stop/60, stop%60)
			}
		}
		e.Text = strings.TrimSpace(syntax.StripAttributes(line[col:]))
		e.textCol = col
		e.Notify, e.Event = entryFlags(spans)
		e.Depth = edit.Indent(line) // a rank once the day is read
		days[date] = append(days[date], e)
		indents[date] = append(indents[date], e.Depth)
	}
	for date, ws := range indents {
		sort.Ints(ws)
		rank, n := map[int]int{}, 0
		for _, w := range ws {
			if _, ok := rank[w]; !ok {
				rank[w] = n
				n++
			}
		}
		for i := range days[date] {
			days[date][i].Depth = rank[days[date][i].Depth]
		}
	}
	return days
}
