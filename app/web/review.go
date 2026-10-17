package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"math"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The domain views the plugin has in Neovim, read-only on the web:
//
//	/okr     objectives by period: progress against the time passed, their
//	         key results and the projects behind them (services/okr)
//	/review  the week: inbox, focus, objectives, what got done, what is due,
//	         projects without a next action, time spent and XP
//	         (ui/review's weekly findings)

// areaLinks: links to the areas @a(...) values name.
func (s *Server) areaLinks(values []string, from string) []linkedItem {
	var out []linkedItem
	for _, a := range values {
		for _, def := range areaDefinitions(a) {
			title := a
			if res, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{}); err == nil && res != nil {
				if n := res.Doc.NodeAt(res.Lnum); n != nil && !n.IsRoot() {
					title = n.Text
				}
			}
			out = append(out, linkedItem{Title: title, URL: s.linkURL(def, from)})
		}
	}
	return out
}

// okrKR is a key result with its projects as rows.
type okrKR struct {
	webKR
	Rows []projectRow
}

type okrObjective struct {
	*webObjective
	AreaLinks []linkedItem
	KRs       []okrKR
}

type okrPeriod struct {
	Span    string // "3M-2026-Q4"
	Window  string
	Elapsed int // percent of the window passed
	List    []okrObjective
}

func (s *Server) handleOKR(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	all := s.allProjects()
	krs := s.keyResults(all, now)
	today := now.Format("2006-01-02")
	var current, later, past, done []okrObjective
	for _, o := range s.objectives(all, now) {
		x := okrObjective{webObjective: o, AreaLinks: s.areaLinks(o.Areas, o.Rel)}
		for _, kr := range o.KRs {
			k := okrKR{webKR: kr}
			for _, p := range kr.Projects {
				k.Rows = append(k.Rows, s.row(p, nil, krs))
			}
			x.KRs = append(x.KRs, k)
		}
		switch {
		case o.Done != "":
			done = append(done, x)
		case o.Start.Format("2006-01-02") > today:
			later = append(later, x)
		case o.End.Format("2006-01-02") < today:
			past = append(past, x)
		default:
			current = append(current, x)
		}
	}
	// current objectives by period, the shortest (soonest ending) first
	var periods []okrPeriod
	index := map[string]int{}
	for _, o := range current {
		i, ok := index[o.Span]
		if !ok {
			i = len(periods)
			index[o.Span] = i
			periods = append(periods, okrPeriod{Span: o.Span, Window: o.Window(), Elapsed: o.ElapsedPercent()})
		}
		periods[i].List = append(periods[i].List, o)
	}
	sort.SliceStable(periods, func(i, j int) bool {
		return periods[i].List[0].End.Before(periods[j].List[0].End)
	})
	sort.SliceStable(done, func(i, j int) bool { return done[i].Done > done[j].Done })
	if len(done) > 10 {
		done = done[:10]
	}
	s.render(w, r, "okr", http.StatusOK, map[string]any{
		"Title":   "Objectives",
		"Periods": periods,
		"Past":    past,
		"Later":   later,
		"Done":    done,
		"HasOKR":  len(s.okrDocs()) > 0,
	})
}

// =============================================================================
// The weekly review
// =============================================================================

type reviewTask struct {
	Project string // its project's name
	PURL    string
	HTML    template.HTML
	Due     string
	Done    string
	PutOff  int
	URL     string
}

type reviewSpent struct {
	Text    string
	URL     string
	Minutes int
}

type reviewInbox struct {
	HTML template.HTML
	URL  string
}

// weekBounds: the ISO week "2026-W42" (or today's when empty or invalid):
// the week, its Monday and Sunday.
func weekBounds(week string, now time.Time) (string, time.Time, time.Time) {
	day := time.Date(now.Year(), now.Month(), now.Day(), 12, 0, 0, 0, now.Location())
	var y, w int
	if n, err := parseWeek(week); err == nil {
		y, w = n[0], n[1]
		// the Monday of ISO week w: Jan 4 is always in week 1
		jan4 := time.Date(y, 1, 4, 12, 0, 0, 0, now.Location())
		wd := (int(jan4.Weekday()) + 6) % 7
		day = jan4.AddDate(0, 0, -wd+(w-1)*7)
	}
	wd := (int(day.Weekday()) + 6) % 7
	monday := day.AddDate(0, 0, -wd)
	return isoWeek(monday), monday, monday.AddDate(0, 0, 6)
}

func parseWeek(s string) ([2]int, error) {
	var y, w int
	_, err := fmt.Sscanf(s, "%d-W%d", &y, &w)
	if err == nil && (w < 1 || w > 53 || y < 1970 || y > 9999) {
		err = errors.New("no such week")
	}
	return [2]int{y, w}, err
}

// timeSpentIn: minutes per task from notes/.z/time_spent.json for the days
// in [from, to], most first.
func (s *Server) timeSpentIn(from, to string) ([]reviewSpent, int) {
	raw, err := os.ReadFile(s.timeSpentPath())
	if err != nil {
		return nil, 0
	}
	var ts timeSpent
	if json.Unmarshal(raw, &ts) != nil {
		return nil, 0
	}
	by := map[string]*reviewSpent{}
	total := 0
	for day, tasks := range ts.Days {
		if day < from || day > to {
			continue
		}
		for _, t := range tasks {
			key := t.Key
			if key == "" {
				key = t.Rel + ":" + t.Text
			}
			x := by[key]
			if x == nil {
				x = &reviewSpent{Text: t.Text, URL: s.noteURL(t.Rel, t.Lnum)}
				by[key] = x
			}
			x.Minutes += t.Minutes
			total += t.Minutes
		}
	}
	var out []reviewSpent
	for _, x := range by {
		out = append(out, *x)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Minutes != out[j].Minutes {
			return out[i].Minutes > out[j].Minutes
		}
		return out[i].Text < out[j].Text
	})
	return out, total
}

// xpIn: XP awarded in [from, to] by the XP summary Neovim publishes, and
// the hours of estimated work behind it.
func (s *Server) xpIn(from, to string) (xp, hours float64, ok bool) {
	raw := s.xpSummary()
	if raw == nil {
		return 0, 0, false
	}
	var sum struct {
		Awards []struct {
			Date   string  `json:"date"`
			XP     float64 `json:"xp"`
			Effort float64 `json:"effort"`
		} `json:"awards"`
	}
	if json.Unmarshal(raw, &sum) != nil {
		return 0, 0, false
	}
	cal := calibrationOf(raw)
	for _, a := range sum.Awards {
		if a.Date >= from && a.Date <= to {
			xp += a.Effort
		}
	}
	if cal.XPPerHour > 0 {
		hours = xp / cal.XPPerHour
	}
	return math.Round(xp), hours, true
}

func (s *Server) handleReview(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	week, monday, sunday := weekBounds(r.URL.Query().Get("week"), now)
	from, to := monday.Format("2006-01-02"), sunday.Format("2006-01-02")
	today := now.Format("2006-01-02")
	soon := now.AddDate(0, 0, 7).Format("2006-01-02")
	all := s.allProjects()
	krs := s.keyResults(all, now)

	// inbox: what has no home yet
	var inbox []reviewInbox
	if d := s.ix.Doc(inboxRel); d != nil {
		rr := &noteRenderer{s: s, doc: d}
		for i, line := range d.Lines {
			lnum := i + 1
			if lnum <= d.Header().LastLnum || d.InCode(lnum) || strings.TrimSpace(line) == "" {
				continue
			}
			it := syntax.ItemOf(line)
			if it != nil && (it.Mark == "x" || it.Mark == "X") {
				continue
			}
			col := 0
			if it != nil {
				col = it.ContentCol
			}
			inbox = append(inbox, reviewInbox{HTML: template.HTML(strings.TrimSpace(rr.entryHTML(line, lnum, col))), URL: s.noteURL(d.Rel, lnum)})
		}
	}

	// focus and the projects without a next action
	_, focus, earlier := s.focus(all, monday)
	focused := map[*webProject]bool{}
	var focusRows []projectRow
	for _, p := range focus {
		focused[p] = true
		focusRows = append(focusRows, s.row(p, focused, krs))
	}
	var quiet []projectRow
	var completed, overdue, dueSoon, putOff []reviewTask
	for _, p := range all {
		pname, purl := p.Name, s.projectURL(p)
		for _, t := range p.Tasks {
			rt := reviewTask{Project: pname, PURL: purl, HTML: t.HTML, Due: t.Due, Done: t.DoneDate, PutOff: t.PutOff, URL: t.URL}
			switch {
			case t.Done:
				if t.DoneDate >= from && t.DoneDate <= to {
					completed = append(completed, rt)
				}
			case t.Due != "" && t.Due < today:
				overdue = append(overdue, rt)
			case t.Due != "" && t.Due <= soon:
				dueSoon = append(dueSoon, rt)
			}
			if !t.Done && t.PutOff >= 2 {
				putOff = append(putOff, rt)
			}
		}
		if p.Root && len(p.Tasks) == 0 || p.isDone() || len(p.Children) > 0 {
			continue
		}
		if ru := p.rollup(); ru.Open == 0 {
			quiet = append(quiet, s.row(p, focused, krs))
		}
	}
	sort.SliceStable(completed, func(i, j int) bool { return completed[i].Done > completed[j].Done })
	sort.SliceStable(overdue, func(i, j int) bool { return overdue[i].Due < overdue[j].Due })
	sort.SliceStable(dueSoon, func(i, j int) bool { return dueSoon[i].Due < dueSoon[j].Due })
	sort.SliceStable(putOff, func(i, j int) bool { return putOff[i].PutOff > putOff[j].PutOff })

	// calendar tasks done this week (copies of project tasks counted above)
	calDone := 0
	for _, entries := range s.calendarDays(from, to) {
		for _, e := range entries {
			if e.Done && e.Ref == "" && !strings.Contains(e.Src, "@id(") {
				calDone++
			}
		}
	}

	// objectives running this week, the furthest behind first
	var objectives []*webObjective
	var noProjects []webKR
	for _, o := range s.objectives(all, now) {
		if o.Done != "" || o.Start.After(sunday) || o.End.Before(monday) {
			continue
		}
		objectives = append(objectives, o)
		for _, kr := range o.KRs {
			if !kr.Done && len(kr.Projects) == 0 {
				noProjects = append(noProjects, kr)
			}
		}
	}
	sort.SliceStable(objectives, func(i, j int) bool {
		return objectives[i].Elapsed-objectives[i].Progress > objectives[j].Elapsed-objectives[j].Progress
	})

	spent, spentTotal := s.timeSpentIn(from, to)
	if len(spent) > 10 {
		spent = spent[:10]
	}
	xp, xpHours, hasXP := s.xpIn(from, to)
	broken := len(s.current().broken)

	prev, _, _ := weekBounds("", monday.AddDate(0, 0, -7))
	next, _, _ := weekBounds("", monday.AddDate(0, 0, 7))
	s.render(w, r, "review", http.StatusOK, map[string]any{
		"Title":       "Review · " + week,
		"NavTab":      "projects",
		"Week":        week,
		"Range":       monday.Format("Jan 2") + " – " + sunday.Format("Jan 2, 2006"),
		"ThisWeek":    week == isoWeek(now),
		"Prev":        prev,
		"Next":        next,
		"Today":       today,
		"Inbox":       inbox,
		"Focus":       focusRows,
		"Earlier":     earlier,
		"PutOff":      putOff,
		"Objectives":  objectives,
		"NoProjects":  noProjects,
		"Completed":   completed,
		"CalDone":     calDone,
		"Overdue":     overdue,
		"DueSoon":     dueSoon,
		"Quiet":       quiet,
		"Spent":       spent,
		"SpentTotal":  spentTotal,
		"XP":          xp,
		"XPHours":     xpHours,
		"HasXP":       hasXP,
		"BrokenLinks": broken,
	})
}
