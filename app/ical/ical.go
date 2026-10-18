// Package ical reads and writes iCalendar (RFC 5545) for zortex serve: the
// events of a calendar feed (Cozi, Google, a school, ...) expanded into
// occurrences in a date window, and the @share lines of the calendar note
// as a feed for other calendars to subscribe to.
//
// It reads what calendar feeds actually send: VEVENTs with DTSTART/DTEND or
// DURATION (dates, UTC times, TZID times, floating times), RRULE with FREQ
// DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY (with an
// ordinal for monthly and yearly rules: 2TU, -1FR), BYMONTHDAY and BYMONTH;
// EXDATE, RDATE, RECURRENCE-ID overrides and STATUS:CANCELLED. Time zones
// come from Go's zone database by TZID; VTIMEZONE blocks are not read (an
// unknown TZID falls back to the feed's default location).
package ical

import (
	"bufio"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Event is one VEVENT as written: a single event, a recurring one (Rule
// set), or an override of one occurrence of a recurring one (RecurrenceID
// set).
type Event struct {
	UID         string
	Summary     string
	Description string
	Location    string
	Status      string // "CONFIRMED", "TENTATIVE", "CANCELLED", or ""
	Categories  []string
	Start       time.Time
	End         time.Time // exclusive; Start when the event has no length
	AllDay      bool
	Rule        *Rule
	ExDates     []time.Time
	RDates      []time.Time
	// RecurrenceID: the start of the occurrence this event replaces
	RecurrenceID *time.Time
}

// Occurrence is one event on its day(s), in the window asked for.
type Occurrence struct {
	Event
}

// Rule is an RRULE.
type Rule struct {
	Freq       string // DAILY, WEEKLY, MONTHLY, YEARLY
	Interval   int
	Count      int        // 0: no limit
	Until      *time.Time // nil: no end
	ByDay      []WeekdayNum
	ByMonthDay []int
	ByMonth    []int
}

// WeekdayNum is a BYDAY value: "TU" (N 0), "2TU", "-1FR".
type WeekdayNum struct {
	N   int
	Day time.Weekday
}

type prop struct {
	name   string
	params map[string]string
	value  string
}

// unfold joins continuation lines (starting with a space or a tab).
func unfold(r io.Reader) []string {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	var out []string
	for sc.Scan() {
		l := strings.TrimRight(sc.Text(), "\r")
		if (strings.HasPrefix(l, " ") || strings.HasPrefix(l, "\t")) && len(out) > 0 {
			out[len(out)-1] += l[1:]
			continue
		}
		out = append(out, l)
	}
	return out
}

// parseProp: NAME;PARAM=VALUE;PARAM="QUOTED":VALUE
func parseProp(line string) (prop, bool) {
	inQuote, colon := false, -1
	for i, c := range line {
		if c == '"' {
			inQuote = !inQuote
		} else if c == ':' && !inQuote {
			colon = i
			break
		}
	}
	if colon < 0 {
		return prop{}, false
	}
	head, value := line[:colon], line[colon+1:]
	parts := splitParams(head)
	p := prop{name: strings.ToUpper(parts[0]), params: map[string]string{}, value: value}
	for _, kv := range parts[1:] {
		k, v, ok := strings.Cut(kv, "=")
		if ok {
			p.params[strings.ToUpper(k)] = strings.Trim(v, `"`)
		}
	}
	return p, true
}

func splitParams(s string) []string {
	var out []string
	inQuote, start := false, 0
	for i, c := range s {
		switch {
		case c == '"':
			inQuote = !inQuote
		case c == ';' && !inQuote:
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

// Text unescapes a TEXT value: \n, \, \; \\.
func Text(v string) string {
	var b strings.Builder
	for i := 0; i < len(v); i++ {
		if v[i] == '\\' && i+1 < len(v) {
			i++
			switch v[i] {
			case 'n', 'N':
				b.WriteByte('\n')
			default:
				b.WriteByte(v[i])
			}
			continue
		}
		b.WriteByte(v[i])
	}
	return b.String()
}

// Parse reads the VEVENTs of a calendar. Dates, times without a zone
// (floating) and times with an unknown TZID are read in loc.
func Parse(r io.Reader, loc *time.Location) []Event {
	if loc == nil {
		loc = time.Local
	}
	var events []Event
	var cur []prop
	depth := 0 // inside VEVENT; nested blocks (VALARM) are skipped
	for _, line := range unfold(r) {
		up := strings.ToUpper(line)
		switch {
		case up == "BEGIN:VEVENT":
			cur, depth = nil, 1
			continue
		case strings.HasPrefix(up, "BEGIN:") && depth > 0:
			depth++
			continue
		case up == "END:VEVENT" && depth == 1:
			if e, ok := toEvent(cur, loc); ok {
				events = append(events, e)
			}
			depth = 0
			continue
		case strings.HasPrefix(up, "END:") && depth > 1:
			depth--
			continue
		}
		if depth == 1 {
			if p, ok := parseProp(line); ok {
				cur = append(cur, p)
			}
		}
	}
	return events
}

func toEvent(props []prop, loc *time.Location) (Event, bool) {
	var e Event
	var hasStart, hasEnd bool
	var dur time.Duration
	var hasDur bool
	for _, p := range props {
		switch p.name {
		case "UID":
			e.UID = p.value
		case "SUMMARY":
			e.Summary = Text(p.value)
		case "DESCRIPTION":
			e.Description = Text(p.value)
		case "LOCATION":
			e.Location = Text(p.value)
		case "STATUS":
			e.Status = strings.ToUpper(strings.TrimSpace(p.value))
		case "CATEGORIES":
			for _, c := range strings.Split(Text(p.value), ",") {
				if c = strings.TrimSpace(c); c != "" {
					e.Categories = append(e.Categories, c)
				}
			}
		case "DTSTART":
			t, allDay, ok := parseTime(p.value, p.params, loc)
			if !ok {
				return e, false
			}
			e.Start, e.AllDay, hasStart = t, allDay, true
		case "DTEND":
			if t, _, ok := parseTime(p.value, p.params, loc); ok {
				e.End, hasEnd = t, true
			}
		case "DURATION":
			if d, ok := parseDuration(p.value); ok {
				dur, hasDur = d, true
			}
		case "RRULE":
			if r, ok := parseRule(p.value, loc); ok {
				e.Rule = r
			}
		case "EXDATE":
			e.ExDates = append(e.ExDates, parseTimes(p, loc)...)
		case "RDATE":
			e.RDates = append(e.RDates, parseTimes(p, loc)...)
		case "RECURRENCE-ID":
			if t, _, ok := parseTime(p.value, p.params, loc); ok {
				e.RecurrenceID = &t
			}
		}
	}
	if !hasStart {
		return e, false
	}
	switch {
	case hasEnd:
	case hasDur:
		e.End = e.Start.Add(dur)
	case e.AllDay:
		e.End = e.Start.AddDate(0, 0, 1)
	default:
		e.End = e.Start
	}
	if e.End.Before(e.Start) {
		e.End = e.Start
	}
	return e, true
}

func parseTimes(p prop, loc *time.Location) []time.Time {
	var out []time.Time
	for _, v := range strings.Split(p.value, ",") {
		if t, _, ok := parseTime(strings.TrimSpace(v), p.params, loc); ok {
			out = append(out, t)
		}
	}
	return out
}

// parseTime reads a DATE or DATE-TIME value: 20261021, 20261021T160000Z,
// 20261021T160000 with TZID, or floating. The time keeps its own zone (UTC,
// the TZID's, or loc for dates and floating times), so a rule repeats it at
// the same wall-clock time there; Expand returns occurrences in the
// window's zone.
func parseTime(v string, params map[string]string, loc *time.Location) (time.Time, bool, bool) {
	v = strings.TrimSpace(v)
	if params["VALUE"] == "DATE" || len(v) == 8 {
		t, err := time.ParseInLocation("20060102", v[:min(8, len(v))], loc)
		return t, true, err == nil
	}
	if strings.HasSuffix(v, "Z") {
		t, err := time.Parse("20060102T150405Z", v)
		return t, false, err == nil
	}
	in := loc
	if tz := params["TZID"]; tz != "" {
		if l, err := time.LoadLocation(strings.TrimPrefix(tz, "/")); err == nil {
			in = l
		}
	}
	t, err := time.ParseInLocation("20060102T150405", v, in)
	return t, false, err == nil
}

// parseDuration reads P1W, P1D, PT1H30M, -PT15M, P1DT2H.
func parseDuration(v string) (time.Duration, bool) {
	v = strings.TrimSpace(strings.ToUpper(v))
	neg := strings.HasPrefix(v, "-")
	v = strings.TrimLeft(v, "+-")
	if !strings.HasPrefix(v, "P") {
		return 0, false
	}
	v = v[1:]
	var d time.Duration
	inTime := false
	num := ""
	for _, c := range v {
		switch {
		case c == 'T':
			inTime = true
		case c >= '0' && c <= '9':
			num += string(c)
		default:
			n, err := strconv.Atoi(num)
			if err != nil {
				return 0, false
			}
			num = ""
			switch {
			case c == 'W':
				d += time.Duration(n) * 7 * 24 * time.Hour
			case c == 'D':
				d += time.Duration(n) * 24 * time.Hour
			case c == 'H' && inTime:
				d += time.Duration(n) * time.Hour
			case c == 'M' && inTime:
				d += time.Duration(n) * time.Minute
			case c == 'S' && inTime:
				d += time.Duration(n) * time.Second
			default:
				return 0, false
			}
		}
	}
	if neg {
		d = -d
	}
	return d, true
}

var weekdays = map[string]time.Weekday{
	"SU": time.Sunday, "MO": time.Monday, "TU": time.Tuesday, "WE": time.Wednesday,
	"TH": time.Thursday, "FR": time.Friday, "SA": time.Saturday,
}

func parseRule(v string, loc *time.Location) (*Rule, bool) {
	r := &Rule{Interval: 1}
	for _, part := range strings.Split(v, ";") {
		k, val, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		val = strings.ToUpper(strings.TrimSpace(val))
		switch strings.ToUpper(k) {
		case "FREQ":
			r.Freq = val
		case "INTERVAL":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				r.Interval = n
			}
		case "COUNT":
			r.Count, _ = strconv.Atoi(val)
		case "UNTIL":
			if t, _, ok := parseTime(val, map[string]string{}, loc); ok {
				r.Until = &t
			}
		case "BYDAY":
			for _, d := range strings.Split(val, ",") {
				d = strings.TrimSpace(d)
				if len(d) < 2 {
					continue
				}
				wd, ok := weekdays[d[len(d)-2:]]
				if !ok {
					continue
				}
				n := 0
				if pre := d[:len(d)-2]; pre != "" {
					n, _ = strconv.Atoi(strings.TrimPrefix(pre, "+"))
				}
				r.ByDay = append(r.ByDay, WeekdayNum{N: n, Day: wd})
			}
		case "BYMONTHDAY":
			for _, d := range strings.Split(val, ",") {
				if n, err := strconv.Atoi(strings.TrimSpace(d)); err == nil && n != 0 {
					r.ByMonthDay = append(r.ByMonthDay, n)
				}
			}
		case "BYMONTH":
			for _, d := range strings.Split(val, ",") {
				if n, err := strconv.Atoi(strings.TrimSpace(d)); err == nil && n >= 1 && n <= 12 {
					r.ByMonth = append(r.ByMonth, n)
				}
			}
		}
	}
	switch r.Freq {
	case "DAILY", "WEEKLY", "MONTHLY", "YEARLY":
		return r, true
	}
	return nil, false
}

// =============================================================================
// Expanding into occurrences
// =============================================================================

const maxSteps = 20000

// starts lists the start times of a recurring event's occurrences, in
// order, up to `to` (and the rule's COUNT and UNTIL). Wall-clock times are
// kept across daylight-saving changes in the event's own location.
func starts(e Event, to time.Time) []time.Time {
	r := e.Rule
	s := e.Start
	loc := s.Location()
	h, mi, sec := s.Clock()
	at := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, h, mi, sec, 0, loc) }
	var out []time.Time
	n := 0
	add := func(t time.Time) bool { // false: stop
		if t.Before(s) {
			return true
		}
		if r.Until != nil && t.After(*r.Until) {
			return false
		}
		if t.After(to) {
			return false
		}
		n++
		if r.Count > 0 && n > r.Count {
			return false
		}
		out = append(out, t)
		return true
	}
	monthOK := func(m time.Month) bool {
		if len(r.ByMonth) == 0 {
			return true
		}
		for _, x := range r.ByMonth {
			if time.Month(x) == m {
				return true
			}
		}
		return false
	}
	// the days of month (y, m) the rule picks, in order
	daysIn := func(y int, m time.Month, defaultDay int) []int {
		last := time.Date(y, m+1, 0, 0, 0, 0, 0, loc).Day()
		pick := map[int]bool{}
		for _, md := range r.ByMonthDay {
			d := md
			if md < 0 {
				d = last + md + 1
			}
			if d >= 1 && d <= last {
				pick[d] = true
			}
		}
		for _, bd := range r.ByDay {
			var ds []int
			for d := 1; d <= last; d++ {
				if time.Date(y, m, d, 0, 0, 0, 0, loc).Weekday() == bd.Day {
					ds = append(ds, d)
				}
			}
			switch {
			case bd.N > 0 && bd.N <= len(ds):
				pick[ds[bd.N-1]] = true
			case bd.N < 0 && -bd.N <= len(ds):
				pick[ds[len(ds)+bd.N]] = true
			case bd.N == 0:
				for _, d := range ds {
					pick[d] = true
				}
			}
		}
		if len(r.ByMonthDay) == 0 && len(r.ByDay) == 0 {
			if defaultDay <= last {
				pick[defaultDay] = true
			}
		}
		var days []int
		for d := range pick {
			days = append(days, d)
		}
		sort.Ints(days)
		return days
	}
	steps := 0
	switch r.Freq {
	case "DAILY":
		for d := s; steps < maxSteps; d = at(d.Year(), d.Month(), d.Day()+r.Interval) {
			steps++
			if !monthOK(d.Month()) || !weekdayOK(r, d.Weekday()) || !monthDayOK(r, d) {
				if d.After(to) || (r.Until != nil && d.After(*r.Until)) {
					break
				}
				continue
			}
			if !add(d) {
				break
			}
		}
	case "WEEKLY":
		days := []time.Weekday{s.Weekday()}
		if len(r.ByDay) > 0 {
			days = nil
			for _, bd := range r.ByDay {
				days = append(days, bd.Day)
			}
		}
		// the week's Monday (RFC 5545's default WKST)
		off := (int(s.Weekday()) + 6) % 7
		week := at(s.Year(), s.Month(), s.Day()-off)
	weeks:
		for ; steps < maxSteps; week = at(week.Year(), week.Month(), week.Day()+7*r.Interval) {
			steps++
			var ts []time.Time
			for _, wd := range days {
				ts = append(ts, at(week.Year(), week.Month(), week.Day()+(int(wd)+6)%7))
			}
			sort.Slice(ts, func(i, j int) bool { return ts[i].Before(ts[j]) })
			for _, t := range ts {
				if !monthOK(t.Month()) {
					continue
				}
				if !add(t) {
					break weeks
				}
			}
			if week.After(to) {
				break
			}
		}
	case "MONTHLY":
	months:
		for m := 0; steps < maxSteps; m += r.Interval {
			steps++
			first := time.Date(s.Year(), s.Month()+time.Month(m), 1, 0, 0, 0, 0, loc)
			if first.After(to) {
				break
			}
			if !monthOK(first.Month()) {
				continue
			}
			for _, d := range daysIn(first.Year(), first.Month(), s.Day()) {
				if !add(at(first.Year(), first.Month(), d)) {
					break months
				}
			}
		}
	case "YEARLY":
		monthsOf := r.ByMonth
		if len(monthsOf) == 0 {
			monthsOf = []int{int(s.Month())}
		}
	years:
		for y := s.Year(); steps < maxSteps; y += r.Interval {
			steps++
			if time.Date(y, 1, 1, 0, 0, 0, 0, loc).After(to) {
				break
			}
			for _, mo := range monthsOf {
				for _, d := range daysIn(y, time.Month(mo), s.Day()) {
					if !add(at(y, time.Month(mo), d)) {
						break years
					}
				}
			}
		}
	}
	return out
}

func weekdayOK(r *Rule, wd time.Weekday) bool {
	if len(r.ByDay) == 0 {
		return true
	}
	for _, bd := range r.ByDay {
		if bd.Day == wd {
			return true
		}
	}
	return false
}

func monthDayOK(r *Rule, t time.Time) bool {
	if len(r.ByMonthDay) == 0 {
		return true
	}
	last := time.Date(t.Year(), t.Month()+1, 0, 0, 0, 0, 0, t.Location()).Day()
	for _, md := range r.ByMonthDay {
		d := md
		if md < 0 {
			d = last + md + 1
		}
		if d == t.Day() {
			return true
		}
	}
	return false
}

func sameStart(a, b time.Time, allDay bool) bool {
	if allDay {
		ay, am, ad := a.Date()
		by, bm, bd := b.Date()
		return ay == by && am == bm && ad == bd
	}
	return a.Equal(b)
}

// Expand returns the occurrences of the events that overlap [from, to),
// sorted by start and in from's zone: recurring events expanded (EXDATE and
// RDATE applied, an override with RECURRENCE-ID replacing its occurrence),
// cancelled ones left out.
func Expand(events []Event, from, to time.Time) []Occurrence {
	loc := from.Location()
	overrides := map[string][]Event{}
	for _, e := range events {
		if e.RecurrenceID != nil {
			overrides[e.UID] = append(overrides[e.UID], e)
		}
	}
	var out []Occurrence
	keep := func(e Event) {
		if e.Status == "CANCELLED" {
			return
		}
		end := e.End
		if !end.After(e.Start) {
			end = e.Start.Add(time.Nanosecond)
		}
		if end.After(from) && e.Start.Before(to) {
			if !e.AllDay {
				e.Start, e.End = e.Start.In(loc), e.End.In(loc)
			}
			out = append(out, Occurrence{Event: e})
		}
	}
	for _, e := range events {
		if e.RecurrenceID != nil {
			continue // placed with its series (or alone when the series is gone)
		}
		if e.Rule == nil && len(e.RDates) == 0 {
			keep(e)
			continue
		}
		length := e.End.Sub(e.Start)
		var ts []time.Time
		if e.Rule != nil {
			ts = starts(e, to)
		} else {
			ts = []time.Time{e.Start}
		}
		ts = append(ts, e.RDates...)
	occ:
		for _, t := range ts {
			for _, x := range e.ExDates {
				if sameStart(t, x, e.AllDay) {
					continue occ
				}
			}
			for _, o := range overrides[e.UID] {
				if sameStart(t, *o.RecurrenceID, e.AllDay) {
					continue occ // the override takes its place, below
				}
			}
			one := e
			one.Rule, one.ExDates, one.RDates = nil, nil, nil
			one.Start, one.End = t, t.Add(length)
			keep(one)
		}
	}
	for _, list := range overrides {
		for _, o := range list {
			o.RecurrenceID = nil
			keep(o)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out
}
