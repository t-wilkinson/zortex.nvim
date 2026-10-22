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
	templateRe = regexp.MustCompile(`^\s*([A-Za-z]+):\s*$`)
)

func isCalFence(line string) bool {
	t := strings.TrimLeft(line, " \t")
	return strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~")
}

var dayNames = []string{"sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"}

// templateName: the template a label names ("Weekday:" -> "weekday"), or "".
func templateName(line string) string {
	m := templateRe.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	switch n := strings.ToLower(m[1]); n {
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

// RepeatSpec is @repeat(…)'s value read.
type RepeatSpec struct {
	Weekdays  map[int]bool
	Dates     map[string]bool // "MM-DD"
	Monthdays map[int]bool
	Unit      string // "d" | "w" | "m" | "y" | ""
	N         int
	Bad       bool
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
	yearRe     = regexp.MustCompile(`^(\d{4})`)
)

// ParseRepeat reads @repeat(…): days of the week (sun … sat, weekdays,
// weekends), dates (03-14), days of the month (15, 1st), and daily /
// weekly / monthly / yearly or every n days/weeks/months/years (2w).
func ParseRepeat(spec string) RepeatSpec {
	r := RepeatSpec{Weekdays: map[int]bool{}, Dates: map[string]bool{}, Monthdays: map[int]bool{}}
	for _, tok := range strings.FieldsFunc(strings.ToLower(spec), func(c rune) bool { return c == ',' || c == ' ' || c == '\t' }) {
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
	Spec     RepeatSpec
	From, To string // "YYYY-MM-DD" or "" (@from, @to; @since, @until, their old names)
	Anchor   string // @from, else @born's date
	Born     int    // @born's year, 0 without
}

func attrValue(line, name string) (string, bool) {
	m := regexp.MustCompile(`@` + name + `\(([^)]*)\)`).FindStringSubmatch(line)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// RuleOf: the rule on a line, or nil without @repeat(…).
func RuleOf(line string, lnum int) *Rule {
	spec, ok := attrValue(line, "repeat")
	if !ok {
		return nil
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
	either := func(name, old string) string {
		if v := date(name); v != "" {
			return v
		}
		return date(old)
	}
	r := &Rule{Lnum: lnum, Line: line, Spec: ParseRepeat(spec), From: either("from", "since"), To: either("to", "until")}
	if born, ok := attrValue(line, "born"); ok {
		if m := yearRe.FindStringSubmatch(strings.TrimSpace(born)); m != nil {
			r.Born, _ = strconv.Atoi(m[1])
		}
	}
	r.Anchor = r.From
	if r.Anchor == "" {
		r.Anchor = date("born")
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
	if len(s.Monthdays) > 0 {
		constrained = true
		if !s.Monthdays[t.Day()] {
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
	for _, name := range []string{"repeat", "since", "until", "born"} {
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
