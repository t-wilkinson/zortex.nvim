package web

import (
	"regexp"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Writing the reviews note (reviews.zortex) from the web, as Neovim's
// services/review does: one "# 2026-W43" entry per week, newest first, its
// days ("## 2026-10-21") inside, each made from the note's "# Templates"
// (## Weekly, ## Daily) when missing; the week's focus is the projects
// linked under its "Focus:" label. These work on lines; the handlers in
// reviewapi.go read and write the file.

var (
	reviewWeekRe  = regexp.MustCompile(`^#\s+(\d{4}-W\d{2})\b`)
	reviewDayRe   = regexp.MustCompile(`^##\s+(\d{4}-\d{2}-\d{2})\b`)
	reviewFocusRe = regexp.MustCompile(`^(\s*)[Ff]ocus:\s*$`)
	templatesRe   = regexp.MustCompile(`^#\s+[Tt]emplates\s*$`)
	tmplHeadRe    = regexp.MustCompile(`^#+\s+([A-Za-z]+)\s*$`)
	tmplLabelRe   = regexp.MustCompile(`^\s*([A-Za-z]+):\s*$`)
)

var (
	defaultWeekTemplate = []string{"Focus:", "", "Wins:", "", "Lessons:"}
	defaultDayTemplate  = []string{"Done:", "Blocked:", "First thing tomorrow:"}
)

// reviewWeek is a week's entry: its heading, last line, the end of its own
// lines (before its first day), its days and its Focus label.
type reviewWeek struct {
	Week               string
	Lnum, Last, OwnEnd int
	Days               map[string]int
	FocusLnum          int // 0: no Focus label
	FocusFrom, FocusTo int // the lines under it
}

func isFenceLine(line string) bool {
	t := strings.TrimSpace(line)
	return strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~")
}

// reviewEntries: the week entries of the reviews note, by week, and their
// order (services/review entries()).
func reviewEntries(lines []string) (map[string]*reviewWeek, []string) {
	weeks := map[string]*reviewWeek{}
	var order []string
	var cur *reviewWeek
	fence := false
	for i, line := range lines {
		lnum := i + 1
		if isFenceLine(line) {
			fence = !fence
			continue
		}
		if fence {
			continue
		}
		if m := reviewWeekRe.FindStringSubmatch(line); m != nil {
			if cur != nil {
				cur.Last = lnum - 1
			}
			cur = &reviewWeek{Week: m[1], Lnum: lnum, Days: map[string]int{}}
			if weeks[m[1]] == nil {
				weeks[m[1]] = cur
				order = append(order, m[1])
			}
		} else if strings.HasPrefix(line, "# ") || line == "#" {
			if cur != nil {
				cur.Last = lnum - 1
				cur = nil
			}
		} else if cur != nil {
			if m := reviewDayRe.FindStringSubmatch(line); m != nil {
				if _, ok := cur.Days[m[1]]; !ok {
					cur.Days[m[1]] = lnum
				}
				if cur.OwnEnd == 0 {
					cur.OwnEnd = lnum - 1
				}
			}
		}
	}
	if cur != nil {
		cur.Last = len(lines)
	}
	for _, e := range weeks {
		if e.Last == 0 {
			e.Last = len(lines)
		}
		if e.OwnEnd == 0 {
			e.OwnEnd = e.Last
		}
		for l := e.Lnum + 1; l <= e.OwnEnd; l++ {
			m := reviewFocusRe.FindStringSubmatch(lines[l-1])
			if m == nil {
				continue
			}
			indent := len(m[1])
			to := l
			for k := l + 1; k <= e.OwnEnd; k++ {
				c := syntax.Classify(lines[k-1])
				if c.Kind == syntax.KindHeading || c.Kind == syntax.KindBoldHeading || c.Kind == syntax.KindArticle ||
					(c.Kind == syntax.KindLabel && indentWidthOf(lines[k-1]) <= indent) {
					break
				}
				if strings.TrimSpace(lines[k-1]) != "" {
					to = k
				}
			}
			e.FocusLnum, e.FocusFrom, e.FocusTo = l, l+1, to
			break
		}
	}
	return weeks, order
}

func indentWidthOf(line string) int {
	w, _ := indentWidth(line)
	return w
}

// reviewTemplates: the note's "# Templates" section: weekly and daily lines,
// without blank lines around them or their common indent.
func reviewTemplates(lines []string) map[string][]string {
	out := map[string][]string{}
	start, last := 0, len(lines)
	fence := false
	for i, line := range lines {
		if isFenceLine(line) {
			fence = !fence
		} else if !fence && templatesRe.MatchString(line) {
			start = i + 1
			for l := i + 2; l <= len(lines); l++ {
				if strings.HasPrefix(lines[l-1], "# ") {
					last = l - 1
					break
				}
			}
			break
		}
	}
	if start == 0 {
		return out
	}
	names := map[string]string{"weekly": "weekly", "week": "weekly", "daily": "daily", "day": "daily"}
	var cur string
	for l := start + 1; l <= last; l++ {
		line := lines[l-1]
		name := ""
		if m := tmplHeadRe.FindStringSubmatch(line); m != nil {
			name = m[1]
		} else if m := tmplLabelRe.FindStringSubmatch(line); m != nil {
			name = m[1]
		}
		if n, ok := names[strings.ToLower(name)]; ok {
			cur = n
			out[cur] = []string{}
			continue
		}
		if cur != "" {
			out[cur] = append(out[cur], line)
		}
	}
	for name, t := range out {
		for len(t) > 0 && strings.TrimSpace(t[0]) == "" {
			t = t[1:]
		}
		for len(t) > 0 && strings.TrimSpace(t[len(t)-1]) == "" {
			t = t[:len(t)-1]
		}
		indent := -1
		for _, l := range t {
			if strings.TrimSpace(l) != "" {
				w := len(l) - len(strings.TrimLeft(l, " \t"))
				if indent < 0 || w < indent {
					indent = w
				}
			}
		}
		for i, l := range t {
			if indent > 0 && len(l) >= indent {
				t[i] = l[indent:]
			}
		}
		out[name] = t
	}
	return out
}

func reviewTemplate(lines []string, kind string) []string {
	if t, ok := reviewTemplates(lines)[kind]; ok {
		return append([]string(nil), t...)
	}
	if kind == "weekly" {
		return append([]string(nil), defaultWeekTemplate...)
	}
	return append([]string(nil), defaultDayTemplate...)
}

// newReviewsNote: a new reviews note's lines (its templates to edit there).
func newReviewsNote() []string {
	out := []string{"@@Reviews", "", "# Templates", "## Weekly"}
	out = append(out, defaultWeekTemplate...)
	out = append(out, "## Daily")
	out = append(out, defaultDayTemplate...)
	return append(out, "")
}

// insertBlock puts block before line `at`, with a blank line between it and
// non-blank lines around it; returns the lines and the block's first line.
func insertBlock(lines []string, at int, block []string) ([]string, int) {
	add := append([]string(nil), block...)
	first := at
	if at > 1 && strings.TrimSpace(lines[at-2]) != "" {
		add = append([]string{""}, add...)
		first = at + 1
	}
	if at <= len(lines) && strings.TrimSpace(lines[at-1]) != "" {
		add = append(add, "")
	}
	out := append([]string(nil), lines[:at-1]...)
	out = append(out, add...)
	return append(out, lines[at-1:]...), first
}

// ensureWeek: the line of "# <week>", the entry made from its template when
// missing: newest first, before the first older week.
func ensureWeek(lines []string, week string) ([]string, int) {
	weeks, order := reviewEntries(lines)
	if e := weeks[week]; e != nil {
		return lines, e.Lnum
	}
	at := 0
	for _, wk := range order {
		if wk < week {
			at = weeks[wk].Lnum
			break
		}
	}
	if at == 0 {
		at = len(lines) + 1
		// the oldest week: before the templates when they come after every week
		tmpl := 0
		for i, l := range lines {
			if templatesRe.MatchString(l) {
				tmpl = i + 1
				break
			}
		}
		if n := len(order); tmpl > 0 && n > 0 && tmpl > weeks[order[n-1]].Lnum {
			at = tmpl
		}
	}
	block := append([]string{"# " + week}, reviewTemplate(lines, "weekly")...)
	return insertBlock(lines, at, block)
}

// ensureDay: the line of "## <date>" in its week's entry (both made when
// missing): newest first, before the week's first older day.
func ensureDay(lines []string, date, week string) ([]string, int) {
	lines, _ = ensureWeek(lines, week)
	weeks, _ := reviewEntries(lines)
	e := weeks[week]
	if l, ok := e.Days[date]; ok {
		return lines, l
	}
	at := 0
	for l := e.OwnEnd + 1; l <= e.Last; l++ {
		if m := reviewDayRe.FindStringSubmatch(lines[l-1]); m != nil && m[1] < date {
			at = l
			break
		}
	}
	if at == 0 {
		at = e.Lnum + 1
		for l := e.Last; l >= e.Lnum; l-- {
			if strings.TrimSpace(lines[l-1]) != "" {
				at = l + 1
				break
			}
		}
	}
	block := append([]string{"## " + date}, reviewTemplate(lines, "daily")...)
	return insertBlock(lines, at, block)
}

// entryRange: the lines of an entry's own text: a week's up to its first
// day, a day's up to the next day or the end of its week.
func entryRange(lines []string, week, date string) (from, to int, ok bool) {
	weeks, _ := reviewEntries(lines)
	e := weeks[week]
	if e == nil {
		return 0, 0, false
	}
	if date == "" {
		return e.Lnum + 1, e.OwnEnd, true
	}
	start, ok := e.Days[date]
	if !ok {
		return 0, 0, false
	}
	end := e.Last
	for l := start + 1; l <= e.Last; l++ {
		if reviewDayRe.MatchString(lines[l-1]) || strings.HasPrefix(lines[l-1], "## ") {
			end = l - 1
			break
		}
	}
	return start + 1, end, true
}

// entryLabels: the labels of an entry's own lines, in order ("Wins",
// "Lessons"), Focus left out.
func entryLabels(lines []string, from, to int) []string {
	var out []string
	for l := from; l <= to && l <= len(lines); l++ {
		c := syntax.Classify(lines[l-1])
		if c.Kind != syntax.KindLabel {
			continue
		}
		name := strings.TrimSuffix(strings.TrimSpace(lines[l-1]), ":")
		if !strings.EqualFold(name, "focus") {
			out = append(out, name)
		}
	}
	return out
}

// addUnderLabel: "- text" after the last line under `label` (in
// lines[from..to]); the label is added at the end of the range when the
// entry doesn't have it. Returns the lines and the new line's number.
func addUnderLabel(lines []string, from, to int, label, text string) ([]string, int) {
	item := "- " + strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(text), "- "))
	at := 0
	for l := from; l <= to && l <= len(lines); l++ {
		name := strings.TrimSuffix(strings.TrimSpace(lines[l-1]), ":")
		if syntax.Classify(lines[l-1]).Kind != syntax.KindLabel || !strings.EqualFold(name, label) {
			continue
		}
		indent := indentWidthOf(lines[l-1])
		pad := lines[l-1][:len(lines[l-1])-len(strings.TrimLeft(lines[l-1], " \t"))]
		last := l
		for k := l + 1; k <= to && k <= len(lines); k++ {
			c := syntax.Classify(lines[k-1])
			if c.Kind == syntax.KindHeading || c.Kind == syntax.KindBoldHeading ||
				(c.Kind == syntax.KindLabel && indentWidthOf(lines[k-1]) <= indent) {
				break
			}
			if strings.TrimSpace(lines[k-1]) != "" {
				last = k
			}
		}
		item = pad + item
		at = last + 1
		break
	}
	if at == 0 {
		// no such label: add it after the entry's last non-blank line
		end := from - 1
		for l := to; l >= from; l-- {
			if strings.TrimSpace(lines[l-1]) != "" {
				end = l
				break
			}
		}
		out := append([]string(nil), lines[:end]...)
		out = append(out, label+":", item)
		return append(out, lines[end:]...), end + 2
	}
	out := append([]string(nil), lines[:at-1]...)
	out = append(out, item)
	return append(out, lines[at-1:]...), at
}
