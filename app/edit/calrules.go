package edit

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The top of the calendar note, above its first day: "# Templates" (the
// lines a new day starts with, by a label naming the day) and "# Repeating"
// (items with @repeat(…), shown on the days they land on). As the plugin's
// services/calendar_rules; tests/fixtures/calendar.json is the contract.

// Span is a range of lines, both ends included (1-based).
type Span struct{ First, Last int }

// CalendarSections: the Templates and Repeating sections of a calendar,
// above its first day. Each runs to the next heading of its level or above,
// or to the first day.
func CalendarSections(lines []string) (templates, repeating []Span) {
	kind, level, first := "", 0, 0
	close := func(last int) {
		if kind != "" && last >= first {
			if kind == "templates" {
				templates = append(templates, Span{first, last})
			} else {
				repeating = append(repeating, Span{first, last})
			}
		}
		kind = ""
	}
	inCode := false
	for i, line := range lines {
		lnum := i + 1
		if isCalFence(line) {
			inCode = !inCode
			continue
		}
		if inCode {
			continue
		}
		if _, ok := DateHeading(line); ok {
			close(lnum - 1)
			return
		}
		if m := headingRe.FindStringSubmatch(line); m != nil {
			if kind != "" && len(m[1]) <= level {
				close(lnum - 1)
			}
			if t := strings.ToLower(m[2]); kind == "" && (t == "templates" || t == "repeating") {
				kind, level, first = t, len(m[1]), lnum+1
			}
		}
	}
	close(len(lines))
	return
}

var (
	headingRe  = regexp.MustCompile(`^(#+)\s+(.*?)\s*$`)
	templateRe = regexp.MustCompile(`^(?:\s*([A-Za-z]+):|#+\s+([A-Za-z]+))\s*$`)
)

func isCalFence(line string) bool {
	t := strings.TrimLeft(line, " \t")
	return strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~")
}

var dayNames = []string{"sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"}

// templateName: the template a label or a heading names ("Weekday:",
// "## Weekday" -> "weekday"), or "".
func templateName(line string) string {
	m := templateRe.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	switch n := strings.ToLower(m[1] + m[2]); n {
	case "daily":
		return n
	case "weekday", "weekdays":
		return "weekday"
	case "weekend", "weekends":
		return "weekend"
	default:
		for _, d := range dayNames {
			if n == d || n == d[:3] {
				return d
			}
		}
	}
	return ""
}

// Templates: the calendar's day templates by name, each without its leading
// and trailing blank lines and its common indent.
func Templates(lines []string) map[string][]string {
	out := map[string][]string{}
	tspans, _ := CalendarSections(lines)
	for _, sp := range tspans {
		cur := ""
		for l := sp.First; l <= sp.Last; l++ {
			line := lines[l-1]
			if name := templateName(line); name != "" {
				cur = name
				out[cur] = []string{}
			} else if cur != "" {
				out[cur] = append(out[cur], line)
			}
		}
	}
	for name, t := range out {
		for len(t) > 0 && blankLine(t[0]) {
			t = t[1:]
		}
		for len(t) > 0 && blankLine(t[len(t)-1]) {
			t = t[:len(t)-1]
		}
		indent := -1
		for _, l := range t {
			if !blankLine(l) {
				w := len(l) - len(strings.TrimLeft(l, " \t"))
				if indent < 0 || w < indent {
					indent = w
				}
			}
		}
		res := make([]string, len(t))
		for i, l := range t {
			if indent > 0 && len(l) >= indent {
				l = l[indent:]
			} else if indent > 0 {
				l = ""
			}
			res[i] = l
		}
		out[name] = res
	}
	return out
}

func weekdayOf(date string) int {
	t, err := time.Parse("2006-01-02", date)
	if err != nil {
		return 0
	}
	return int(t.Weekday()) + 1 // 1 = Sunday, as Lua's os.date("*t").wday
}

// Template: the lines a new day `date` starts with: its weekday's template,
// else weekday / weekend, else daily.
func Template(lines []string, date string) []string {
	t := Templates(lines)
	wd := weekdayOf(date)
	if wd == 0 {
		return nil
	}
	group := "weekday"
	if wd == 1 || wd == 7 {
		group = "weekend"
	}
	for _, name := range []string{dayNames[wd-1], group, "daily"} {
		if l, ok := t[name]; ok {
			return append([]string{}, l...)
		}
	}
	return []string{}
}

// RepeatSpec is @repeat(…) and @on(…)'s values read.
type RepeatSpec struct {
	Weekdays  map[int]bool
	Dates     map[string]bool // "MM-DD"
	Monthdays map[int]bool
	Nth       map[[2]int]bool // {2, 3}: the 2nd Tuesday; {-1, 6}: the last Friday
	LastDay   bool            // the month's last day
	Unit      string          // "d" | "w" | "m" | "y" | ""
	N         int
	Bad       bool
}

// ordinals: "2nd tue", which weekday of the month (-1: the last)
var ordinals = map[string]int{
	"1st": 1, "first": 1, "2nd": 2, "second": 2, "3rd": 3, "third": 3,
	"4th": 4, "fourth": 4, "5th": 5, "fifth": 5, "last": -1,
}

var weekdayNames = map[string]int{
	"sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
	"wed": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
	"fri": 6, "friday": 6, "sat": 7, "saturday": 7,
}

var (
	everyRe    = regexp.MustCompile(`^(\d+)([dwmy])$`)
	monthDayRe = regexp.MustCompile(`^(\d\d?)(?:[snrt][tdh])?$`)
	mmddRe     = regexp.MustCompile(`^\d\d-\d\d$`)
	isoDateRe  = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
)

// ParseRepeat reads @repeat(…) and @on(…): days of the week (sun … sat,
// weekdays, weekends), dates (03-14), days of the month (15, 1st), a
// weekday of the month (2nd tue, last fri), the month's last day (last),
// and daily / weekly / monthly / yearly or every n days/weeks/months/years
// (2w).
func ParseRepeat(spec string) RepeatSpec {
	r := RepeatSpec{Weekdays: map[int]bool{}, Dates: map[string]bool{}, Monthdays: map[int]bool{}, Nth: map[[2]int]bool{}}
	toks := strings.FieldsFunc(strings.ToLower(spec), func(c rune) bool { return c == ',' || c == ' ' || c == '\t' })
	for i := 0; i < len(toks); i++ {
		tok := toks[i]
		if n, ok := ordinals[tok]; ok && i+1 < len(toks) {
			if d, ok := weekdayNames[toks[i+1]]; ok {
				r.Nth[[2]int{n, d}] = true
				i++
				continue
			}
		}
		if tok == "last" {
			r.LastDay = true
			continue
		}
		if d, ok := weekdayNames[tok]; ok {
			r.Weekdays[d] = true
			continue
		}
		switch tok {
		case "weekdays", "weekday":
			for d := 2; d <= 6; d++ {
				r.Weekdays[d] = true
			}
			continue
		case "weekends", "weekend":
			r.Weekdays[1], r.Weekdays[7] = true, true
			continue
		case "daily":
			r.Unit, r.N = "d", 1
			continue
		case "weekly":
			r.Unit, r.N = "w", 1
			continue
		case "monthly":
			r.Unit, r.N = "m", 1
			continue
		case "yearly", "annually":
			r.Unit, r.N = "y", 1
			continue
		}
		if mmddRe.MatchString(tok) {
			r.Dates[tok] = true
		} else if m := monthDayRe.FindStringSubmatch(tok); m != nil {
			n, _ := strconv.Atoi(m[1])
			if n >= 1 && n <= 31 {
				r.Monthdays[n] = true
			} else {
				r.Bad = true
			}
		} else if m := everyRe.FindStringSubmatch(tok); m != nil {
			n, _ := strconv.Atoi(m[1])
			if n > 0 {
				r.Unit, r.N = m[2], n
			} else {
				r.Bad = true
			}
		} else {
			r.Bad = true
		}
	}
	return r
}

// Rule is an item of the Repeating section.
type Rule struct {
	Lnum     int
	Line     string
	Spec     RepeatSpec // @repeat and @on together
	From, To string     // "YYYY-MM-DD" or "" (@from, @to)
	Anchor   string     // @from, else @born's date
	Born     int        // @born's year, 0 without
	BadOn    bool       // @on holds how often, not days
}

func attrValue(line, name string) (string, bool) {
	m := regexp.MustCompile(`@` + name + `\(([^)]*)\)`).FindStringSubmatch(line)
	if m == nil {
		return "", false
	}
	return m[1], true
}

var (
	bornYear     = regexp.MustCompile(`^(\d{4})$`)
	bornISO      = regexp.MustCompile(`^(\d{4})-(\d{1,2})-(\d{1,2})$`)
	bornUS       = regexp.MustCompile(`^(\d{1,2})-(\d{1,2})-(\d{4})$`)
	bornMD       = regexp.MustCompile(`^(\d{1,2})-(\d{1,2})$`)
	bornNameDY   = regexp.MustCompile(`^([a-z]+)\.?\s+(\d{1,2})[a-z]*,?\s*(\d{4})$`)
	bornNameD    = regexp.MustCompile(`^([a-z]+)\.?\s+(\d{1,2})[a-z]*$`)
	bornDNameY   = regexp.MustCompile(`^(\d{1,2})[a-z]*\s+([a-z]+)\.?,?\s*(\d{4})$`)
	bornDName    = regexp.MustCompile(`^(\d{1,2})[a-z]*\s+([a-z]+)\.?$`)
	monthNames   = []string{"january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"}
	bornAnyMonth = func(name string) int {
		if len(name) < 3 {
			return 0
		}
		for i, full := range monthNames {
			if strings.HasPrefix(full, name) {
				return i + 1
			}
		}
		return 0
	}
)

// ParseBorn reads a @born(…) value: year, month, day (0 when not given),
// and whether it is one (services/calendar_rules parse_born): "1990",
// "1990-02-01", "02-01-1990" (month first), "02-01", "Feb 1", "February 1st",
// "Feb 1, 2000", "1 Feb 2000".
func ParseBorn(v string) (year, month, day int, ok bool) {
	v = strings.ToLower(strings.TrimSpace(v))
	atoi := func(s string) int { n, _ := strconv.Atoi(s); return n }
	valid := func(y, m, d int) (int, int, int, bool) {
		if m != 0 && (m < 1 || m > 12) || d != 0 && (d < 1 || d > 31) {
			return 0, 0, 0, false
		}
		return y, m, d, true
	}
	if m := bornYear.FindStringSubmatch(v); m != nil {
		return atoi(m[1]), 0, 0, true
	}
	if m := bornISO.FindStringSubmatch(v); m != nil {
		return valid(atoi(m[1]), atoi(m[2]), atoi(m[3]))
	}
	if m := bornUS.FindStringSubmatch(v); m != nil {
		return valid(atoi(m[3]), atoi(m[1]), atoi(m[2]))
	}
	if m := bornMD.FindStringSubmatch(v); m != nil {
		return valid(0, atoi(m[1]), atoi(m[2]))
	}
	name, d, y := "", "", ""
	if m := bornNameDY.FindStringSubmatch(v); m != nil {
		name, d, y = m[1], m[2], m[3]
	} else if m := bornNameD.FindStringSubmatch(v); m != nil {
		name, d = m[1], m[2]
	} else if m := bornDNameY.FindStringSubmatch(v); m != nil {
		d, name, y = m[1], m[2], m[3]
	} else if m := bornDName.FindStringSubmatch(v); m != nil {
		d, name = m[1], m[2]
	}
	if mo := bornAnyMonth(name); mo > 0 {
		return valid(atoi(y), mo, atoi(d))
	}
	return 0, 0, 0, false
}

// RuleOf: the rule on a line, or nil without @repeat(…), @on(…) or a
// @born(…) with a month and day (a birthday, every year on that day).
func RuleOf(line string, lnum int) *Rule {
	spec, hasRepeat := attrValue(line, "repeat")
	on, hasOn := attrValue(line, "on")
	var by, bm, bd int
	if born, ok := attrValue(line, "born"); ok {
		by, bm, bd, _ = ParseBorn(born)
	}
	if !hasRepeat && !hasOn {
		// a birthday: @born with a month and day repeats every year on it
		if bm == 0 || bd == 0 {
			return nil
		}
		on = fmt.Sprintf("%02d-%02d", bm, bd)
	}
	// the first @name(YYYY-MM-DD) (a @from holding a time is skipped)
	date := func(name string) string {
		for _, m := range regexp.MustCompile(`@`+name+`\(([^)]*)\)`).FindAllStringSubmatch(line, -1) {
			if v := strings.TrimSpace(m[1]); isoDateRe.MatchString(v) {
				return v
			}
		}
		return ""
	}
	r := &Rule{Lnum: lnum, Line: line, Spec: ParseRepeat(spec + "," + on), From: date("from"), To: date("to")}
	r.BadOn = hasOn && ParseRepeat(on).Unit != ""
	r.Born = by
	r.Anchor = r.From
	if r.Anchor == "" && by > 0 && bm > 0 && bd > 0 {
		r.Anchor = fmt.Sprintf("%04d-%02d-%02d", by, bm, bd)
	}
	return r
}

// Rules: every rule of the calendar's Repeating sections, in file order.
func Rules(lines []string) []*Rule {
	var out []*Rule
	_, rspans := CalendarSections(lines)
	for _, sp := range rspans {
		inCode := false
		for l := sp.First; l <= sp.Last; l++ {
			line := lines[l-1]
			if isCalFence(line) {
				inCode = !inCode
				continue
			}
			if inCode || syntax.Classify(line).Kind != syntax.KindItem {
				continue
			}
			if r := RuleOf(line, l); r != nil {
				out = append(out, r)
			}
		}
	}
	return out
}

// Matches reports whether the rule lands on date ("YYYY-MM-DD").
func (r *Rule) Matches(date string) bool {
	s := r.Spec
	if s.Bad {
		return false
	}
	if (r.From != "" && date < r.From) || (r.To != "" && date > r.To) {
		return false
	}
	t, err := time.Parse("2006-01-02", date)
	if err != nil {
		return false
	}
	constrained := false
	if len(s.Weekdays) > 0 {
		constrained = true
		if !s.Weekdays[int(t.Weekday())+1] {
			return false
		}
	}
	if len(s.Dates) > 0 {
		constrained = true
		if !s.Dates[date[5:]] {
			return false
		}
	}
	last := time.Date(t.Year(), t.Month()+1, 0, 12, 0, 0, 0, time.UTC).Day()
	if len(s.Monthdays) > 0 || s.LastDay {
		constrained = true
		if !s.Monthdays[t.Day()] && !(s.LastDay && t.Day() == last) {
			return false
		}
	}
	if len(s.Nth) > 0 {
		constrained = true
		wd := int(t.Weekday()) + 1
		if !s.Nth[[2]int{(t.Day()-1)/7 + 1, wd}] && !(t.Day()+7 > last && s.Nth[[2]int{-1, wd}]) {
			return false
		}
	}
	if s.Unit == "" {
		return constrained
	}
	if s.N == 1 && (constrained || s.Unit == "d") {
		return true
	}
	if r.Anchor == "" || date < r.Anchor {
		return false
	}
	a, err := time.Parse("2006-01-02", r.Anchor)
	if err != nil {
		return false
	}
	days := dayNumber(date) - dayNumber(r.Anchor)
	switch s.Unit {
	case "d":
		return days%s.N == 0
	case "w":
		if constrained {
			return (days/7)%s.N == 0
		}
		return days%(7*s.N) == 0
	case "m":
		months := (t.Year()-a.Year())*12 + int(t.Month()) - int(a.Month())
		return months%s.N == 0 && (constrained || t.Day() == a.Day())
	}
	return (t.Year()-a.Year())%s.N == 0 && (constrained || (t.Month() == a.Month() && t.Day() == a.Day()))
}

// datedFromTo: @from(YYYY-MM-DD) and @to(…) with the spaces before them
var datedFromTo = regexp.MustCompile(`[ \t\n\v\f\r]*@(?:from|to)\([ \t\n\v\f\r]*\d{4}-\d{2}-\d{2}[ \t\n\v\f\r]*\)`)

// PlainLine: the rule's line as a day's line: no indent, no rule attributes
// (@from and @to only when they hold a date: @from(07:00) is a time).
func PlainLine(line string) string {
	line = strings.TrimSpace(line)
	for _, name := range []string{"repeat", "on", "born"} {
		line = RemoveAttribute(line, name)
	}
	return datedFromTo.ReplaceAllString(line, "")
}

// DoneCopy: the line ticking the rule's occurrence on `date` writes into
// the day `today`: the task, done today, with @for(date) when that isn't
// today.
func (r *Rule) DoneCopy(date, today string, newID func() string) (string, error) {
	line, err := Line(PlainLine(r.Line), Done, today, newID)
	if err != nil {
		return "", err
	}
	if date != today {
		line += " @for(" + date + ")"
	}
	return line, nil
}

// Label: "Sam" -> "Sam (36)" on `date` for a rule with @born.
func (r *Rule) Label(text, date string) string {
	if r.Born > 0 && len(date) >= 4 {
		if y, err := strconv.Atoi(date[:4]); err == nil && y >= r.Born {
			return fmt.Sprintf("%s (%d)", text, y-r.Born)
		}
	}
	return text
}

// ForDate: the date a copy stands for (@for(YYYY-MM-DD)), or "".
func ForDate(line string) string {
	if v, ok := attrValue(line, "for"); ok && isoDateRe.MatchString(v) {
		return v
	}
	return ""
}

// Day is a day block of the calendar: its heading and last non-blank line.
type Day struct {
	Date          string
	Heading, Last int
}

// Days: the calendar's day blocks in file order (code blocks skipped).
func Days(lines []string) []Day {
	var out []Day
	fence := false
	for i, l := range lines {
		if isFence(l) {
			fence = !fence
		} else if !fence {
			if date, ok := DateHeading(l); ok {
				out = append(out, Day{Date: date, Heading: i + 1})
			}
		}
	}
	for i := range out {
		stop := len(lines)
		if i+1 < len(out) {
			stop = out[i+1].Heading - 1
		}
		out[i].Last = out[i].Heading
		for l := out[i].Heading + 1; l <= stop; l++ {
			if !blankLine(lines[l-1]) {
				out[i].Last = l
			}
		}
	}
	return out
}

// AddToDay appends `add` at the end of day `date`, at its top level; a new
// day starts from `template` and goes next to its nearest neighbour in time
// (as Neovim's stores/calendar.ensure_date).
func AddToDay(lines []string, date string, template, add []string) []string {
	days := Days(lines)
	for _, d := range days {
		if d.Date == date {
			out := append([]string{}, lines[:d.Last]...)
			out = append(out, add...)
			return append(out, lines[d.Last:]...)
		}
	}
	target := dayNumber(date)
	beforeI, afterI := -1, -1
	var beforeN, afterN int
	for i, b := range days {
		n := dayNumber(b.Date)
		if n < target && (beforeI < 0 || n >= beforeN) {
			beforeI, beforeN = i, n
		} else if n > target && (afterI < 0 || n < afterN) {
			afterI, afterN = i, n
		}
	}
	at := len(lines) + 1
	if afterI >= 0 {
		if beforeI >= 0 && target-beforeN <= afterN-target {
			if beforeI+1 < len(days) {
				at = days[beforeI+1].Heading
			}
		} else {
			at = days[afterI].Heading
		}
	}
	block := append([]string{DateHeadingLine(date)}, template...)
	block = append(block, add...)
	block = append(block, "")
	if at > len(lines) {
		at = len(lines) + 1
		if len(lines) > 0 && !blankLine(lines[len(lines)-1]) {
			block = append([]string{""}, block...)
		}
		block = block[:len(block)-1]
	} else if at > 1 && !blankLine(lines[at-2]) {
		block = append([]string{""}, block...)
	}
	out := append([]string{}, lines[:at-1]...)
	out = append(out, block...)
	return append(out, lines[at-1:]...)
}
