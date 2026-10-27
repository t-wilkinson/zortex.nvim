package edit

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
)

// The calendar note's days and months, as Neovim's services/calendar_days
// (checked against tests/fixtures/caldays.json). A day is a date label and
// the lines under it, up to the next day or the next heading. Days are
// grouped under a heading per month ("# October 2026"; "## October 2026"
// under "# Days"; "2026-10" reads too): a new day goes into its month, next
// to its nearest neighbour in time, and with grouping on a missing month
// heading is made, in month order.

// Months: the month names, January first.
var Months = []string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

var monthOf = func() map[string]int {
	m := map[string]int{}
	for i, name := range Months {
		m[strings.ToLower(name)] = i + 1
		m[strings.ToLower(name[:3])] = i + 1
	}
	return m
}()

var (
	headingLine  = regexp.MustCompile(`^(#+)\s+(.*?)\s*$`)
	monthNumeric = regexp.MustCompile(`^(\d{4})-(\d{2})$`)
	monthNamed   = regexp.MustCompile(`^([A-Za-z]+)\.?\s+(\d{4})$`)
)

// groupDays: whether a new day makes its month's heading when missing
// (Neovim's ui.calendar.group_days; .z/syntax.json "group_days": false
// turns it off).
var groupDays atomic.Bool

func init() { groupDays.Store(true) }

// SetGroupDays turns month headings for new days on or off.
func SetGroupDays(on bool) { groupDays.Store(on) }

// GroupDays: whether new days make their month's heading.
func GroupDays() bool { return groupDays.Load() }

// Heading is a Markdown heading's level and text.
func Heading(line string) (int, string, bool) {
	m := headingLine.FindStringSubmatch(line)
	if m == nil || len(m[1]) > 6 {
		return 0, "", false
	}
	return len(m[1]), m[2], true
}

// MonthHeading is a month heading's "YYYY-MM" and level: "# October 2026",
// "## Oct 2026", "# 2026-10".
func MonthHeading(line string) (string, int, bool) {
	level, text, ok := Heading(line)
	if !ok {
		return "", 0, false
	}
	if m := monthNumeric.FindStringSubmatch(text); m != nil {
		if n, _ := strconv.Atoi(m[2]); n >= 1 && n <= 12 {
			return m[1] + "-" + m[2], level, true
		}
	}
	if m := monthNamed.FindStringSubmatch(text); m != nil {
		if n := monthOf[strings.ToLower(m[1])]; n > 0 {
			return fmt.Sprintf("%s-%02d", m[2], n), level, true
		}
	}
	return "", 0, false
}

// MonthHeadingLine is the heading a new month gets: "# October 2026".
func MonthHeadingLine(ym string, level int) string {
	n, _ := strconv.Atoi(ym[5:7])
	return strings.Repeat("#", level) + " " + Months[n-1] + " " + ym[:4]
}

// DayBoundary: does a day end at this line (another day, or a heading)?
func DayBoundary(line string) bool {
	if _, ok := DateHeading(line); ok {
		return true
	}
	_, _, ok := Heading(line)
	return ok
}

type calMark struct {
	date  string
	level int
	text  string
	lnum  int
}

func scanCalendar(lines []string) []calMark {
	var out []calMark
	fence := false
	for i, l := range lines {
		if isFence(l) {
			fence = !fence
		} else if !fence {
			if date, ok := DateHeading(l); ok {
				out = append(out, calMark{date: date, lnum: i + 1})
			} else if level, text, ok := Heading(l); ok {
				out = append(out, calMark{level: level, text: text, lnum: i + 1})
			}
		}
	}
	return out
}

func lastNonBlank(lines []string, from, stop int) int {
	last := from
	for l := from + 1; l <= stop; l++ {
		if !blankLine(lines[l-1]) {
			last = l
		}
	}
	return last
}

// Day is a day of the calendar: its label's line, the line before the next
// day or heading (Stop), and its last non-blank line.
type Day struct {
	Date    string `json:"date"`
	Heading int    `json:"heading"`
	Stop    int    `json:"stop"`
	Last    int    `json:"last"`
}

// Days: the calendar's days in file order (code blocks skipped).
func Days(lines []string) []Day {
	marks := scanCalendar(lines)
	var out []Day
	for i, mk := range marks {
		if mk.date == "" {
			continue
		}
		stop := len(lines)
		if i+1 < len(marks) {
			stop = marks[i+1].lnum - 1
		}
		out = append(out, Day{Date: mk.date, Heading: mk.lnum, Stop: stop, Last: lastNonBlank(lines, mk.lnum, stop)})
	}
	return out
}

func sectionStop(marks []calMark, i int, lines []string) int {
	for j := i + 1; j < len(marks); j++ {
		if marks[j].level > 0 && marks[j].level <= marks[i].level {
			return marks[j].lnum - 1
		}
	}
	return len(lines)
}

// Month is a month heading and its section.
type Month struct {
	YM      string `json:"ym"`
	Level   int    `json:"level"`
	Heading int    `json:"heading"`
	Stop    int    `json:"stop"`
	Last    int    `json:"last"`
}

// MonthsOf: the calendar's month headings in file order.
func MonthsOf(lines []string) []Month {
	marks := scanCalendar(lines)
	var out []Month
	for i, mk := range marks {
		if mk.level == 0 {
			continue
		}
		if ym, level, ok := MonthHeading(lines[mk.lnum-1]); ok {
			stop := sectionStop(marks, i, lines)
			out = append(out, Month{YM: ym, Level: level, Heading: mk.lnum, Stop: stop, Last: lastNonBlank(lines, mk.lnum, stop)})
		}
	}
	return out
}

// monthContaining: the month whose section holds line lnum, or nil.
func monthContaining(months []Month, lnum int) *Month {
	for i := range months {
		if lnum > months[i].Heading && lnum <= months[i].Stop {
			return &months[i]
		}
	}
	return nil
}

// daysSection: a "# Days" heading's level and the line its section ends on.
func daysSection(lines []string) (level, stop int, ok bool) {
	marks := scanCalendar(lines)
	for i, mk := range marks {
		if mk.level > 0 && strings.ToLower(mk.text) == "days" {
			return mk.level, sectionStop(marks, i, lines), true
		}
	}
	return 0, 0, false
}

// DayOf: the day line lnum belongs to.
func DayOf(lines []string, lnum int) (Day, bool) {
	for _, d := range Days(lines) {
		if lnum >= d.Heading && lnum <= d.Stop {
			return d, true
		}
	}
	return Day{}, false
}

// nearestDay: where a day goes among days: with no later day at fallback,
// else right after the closest earlier day (before the day after it) or
// right before the closest later day when that one is nearer. A day of the
// same date counts as earlier.
func nearestDay(days []Day, date string, fallback int) int {
	target := dayNumber(date)
	beforeI, afterI := -1, -1
	var beforeN, afterN int
	for i, b := range days {
		n := dayNumber(b.Date)
		if n <= target && (beforeI < 0 || n >= beforeN) {
			beforeI, beforeN = i, n
		} else if n > target && (afterI < 0 || n < afterN) {
			afterI, afterN = i, n
		}
	}
	if afterI < 0 {
		return fallback
	}
	if beforeI >= 0 && target-beforeN <= afterN-target {
		if beforeI+1 < len(days) {
			return days[beforeI+1].Heading
		}
		return fallback
	}
	return days[afterI].Heading
}

// PlaceDay: the line a new day goes before, and the month heading to add
// above it ("" for none). group: make a missing month heading.
func PlaceDay(lines []string, date string, group bool) (int, string) {
	ym := date[:7]
	all := Days(lines)
	months := MonthsOf(lines)
	for _, m := range months {
		if m.YM == ym {
			var inside []Day
			for _, d := range all {
				if d.Heading > m.Heading && d.Heading <= m.Stop {
					inside = append(inside, d)
				}
			}
			return nearestDay(inside, date, m.Stop+1), ""
		}
	}
	if !group {
		return nearestDay(all, date, len(lines)+1), ""
	}
	// days of this month not under a month heading yet (a calendar from
	// before grouping): the new day joins them
	var loose []Day
	for _, d := range all {
		if d.Date[:7] == ym && monthContaining(months, d.Heading) == nil {
			loose = append(loose, d)
		}
	}
	if len(loose) > 0 {
		return nearestDay(loose, date, loose[len(loose)-1].Stop+1), ""
	}
	dLevel, dStop, hasDays := daysSection(lines)
	level := 1
	switch {
	case len(months) > 0:
		level = months[0].Level
	case hasDays:
		level = dLevel + 1
	}
	var later *Month
	for i := range months {
		if months[i].YM > ym && (later == nil || months[i].YM < later.YM) {
			later = &months[i]
		}
	}
	at := len(lines) + 1
	switch {
	case later != nil:
		at = later.Heading
	case len(months) > 0:
		at = months[len(months)-1].Stop + 1
	case hasDays:
		at = dStop + 1
	case len(all) > 0:
		at = all[len(all)-1].Stop + 1
	}
	return at, MonthHeadingLine(ym, level)
}

// DayInsert is a new day's lines and where they go; Heading is the day
// label's line once inserted.
type DayInsert struct {
	At      int
	Lines   []string
	Heading int
}

// InsertDay: the lines for a new day (its label, then body) and where they
// go, as Neovim's calendar_days.insert_day. label "" is "**YYYY-MM-DD:**".
func InsertDay(lines []string, date string, body []string, group bool, label string) DayInsert {
	at, monthLine := PlaceDay(lines, date, group)
	var add []string
	if monthLine != "" {
		add = append(add, monthLine, "")
	}
	labelI := len(add)
	if label == "" {
		label = DateHeadingLine(date)
	}
	add = append(add, label)
	add = append(add, body...)
	add = append(add, "")
	if at > len(lines) {
		at = len(lines) + 1
		if len(lines) > 0 && !blankLine(lines[len(lines)-1]) {
			add = append([]string{""}, add...)
			labelI++
		}
		add = add[:len(add)-1]
	} else if at > 1 && !blankLine(lines[at-2]) {
		add = append([]string{""}, add...)
		labelI++
	}
	return DayInsert{At: at, Lines: add, Heading: at + labelI}
}

// Apply: lines with the insert made (a new slice).
func (d DayInsert) Apply(lines []string) []string {
	out := append([]string{}, lines[:d.At-1]...)
	out = append(out, d.Lines...)
	return append(out, lines[d.At-1:]...)
}
