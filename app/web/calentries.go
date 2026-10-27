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

// entryDuration: @dur(…), else a bare @2h, in minutes.
func entryDuration(spans []syntax.Span) float64 {
	var dur, bare float64
	for _, sp := range spans {
		if sp.Type != "attribute" {
			continue
		}
		key := syntax.Lower(sp.Key)
		switch {
		case key == "dur" && dur == 0:
			dur = durationMinutes(sp.Value)
		case sp.Value == "" && bareDur.MatchString(key) && bare == 0:
			bare = durationMinutes(key)
		}
	}
	if dur > 0 {
		return dur
	}
	return bare
}

// lastField: "2026-10-20 09:30" -> "09:30".
func lastField(v string) string {
	f := strings.Fields(v)
	if len(f) == 0 {
		return ""
	}
	return f[len(f)-1]
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
		if d, ok := edit.DateHeading(line); ok && !doc.InCode(lnum) {
			date = d
			continue
		}
		if _, _, ok := edit.Heading(line); ok && !doc.InCode(lnum) {
			date = "" // a heading (a month's) ends the day
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
		// @at(09:30), @from(…) @to(…): the time when the line doesn't start with one
		if start == "" {
			if v, ok := edit.Attribute(line, "at"); ok {
				start = lastField(v)
			} else if v, ok := edit.Attribute(line, "from"); ok {
				start = lastField(v)
				if v, ok := edit.Attribute(line, "to"); ok {
					end = lastField(v)
				}
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

// forCopiesOf: the done copies of repeating tasks that stand for another
// day's occurrence (@for(date)), by that date and their text.
func forCopiesOf(doc *notes.Document, days map[string][]calEntry) map[string]map[string]calEntry {
	out := map[string]map[string]calEntry{}
	for _, entries := range days {
		for _, e := range entries {
			if d := edit.ForDate(doc.Lines[e.Lnum-1]); d != "" {
				if out[d] == nil {
					out[d] = map[string]calEntry{}
				}
				out[d][e.Text] = e
			}
		}
	}
	return out
}

// occurrences: what the repeating rules put on `date`, in rule order (as
// the plugin's stores/calendar.occurrences): Lnum is the rule's line, Text
// its label (with the age for @born); a task done on its day shows as that
// copy (none here), one done another day (@for) takes the copy's state and
// Copy its line. `own`: the day's own entries.
func occurrences(doc *notes.Document, rules []*edit.Rule, own []calEntry, forCopies map[string]map[string]calEntry, date string) []calEntry {
	var out []calEntry
	for _, rule := range rules {
		if !rule.Matches(date) {
			continue
		}
		read := calendarEntries(notes.FromLines("rule", []string{date + ":", rule.Line}), "", "")[date]
		if len(read) == 0 {
			continue
		}
		e := read[0]
		shown := false
		for _, x := range own {
			if x.Text == e.Text && edit.ForDate(doc.Lines[x.Lnum-1]) == "" {
				shown = true
			}
		}
		if shown {
			continue
		}
		e.Lnum, e.Depth, e.Repeat, e.Date = rule.Lnum, 0, true, date
		e.Done = false
		if c, ok := forCopies[date][e.Text]; ok {
			e.Done, e.Copy = c.Done, c.Lnum
		}
		e.Text = rule.Label(e.Text, date)
		out = append(out, e)
	}
	return out
}
