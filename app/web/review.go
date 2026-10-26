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
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The domain views the plugin has in Neovim, on the web:
//
//	/okr               objectives by period: progress against the time
//	                   passed, their key results and the projects behind them
//	                   (services/okr)
//	/review            the week: inbox, focus, objectives, what got done,
//	                   what is due, projects without a next action, time
//	                   spent and XP (ui/review's weekly findings); with
//	                   -writable, its fixes (reviewapi.go): tick and date
//	                   tasks, move inbox lines, pick the focus, write the
//	                   week's entry
//	/review?day=today  the daily review (reviewday.go)

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
	Tier    *okrTier // the tier of the season with this span
}

// okrTier is how far a season got: Neovim's own figure when it published
// this season (the XP summary) or ended it (its history), else an estimate
// here (its objectives' mean progress against the tiers).
type okrTier struct {
	Season    string // "Season 10 Juniper", when Neovim named it
	Name      string // the tier; "" before the first
	Progress  int    // percent
	Next      string
	NextAt    int // percent
	Final     bool
	Estimated bool
}

type summaryTier struct {
	Name string  `json:"name"`
	At   float64 `json:"at"`
}

var defaultTiers = []summaryTier{{"Bronze", 0.25}, {"Silver", 0.5}, {"Gold", 0.7}, {"Platinum", 0.85}, {"Complete", 1}}

// seasonTier: the tier of the season whose span ("3M-2026-Q4") is `span`:
// Neovim's own figure for it when it published this season (the XP summary)
// or ended it (its history); else, for the current calendar quarter, an
// estimate from the objectives of that span (done ones too). nil otherwise.
func (s *Server) seasonTier(span string, all []*webObjective, raw []byte, now time.Time) *okrTier {
	var sum struct {
		Season *struct {
			Name     string        `json:"name"`
			Span     string        `json:"span"`
			Progress float64       `json:"progress"`
			Tier     string        `json:"tier"`
			NextTier string        `json:"next_tier"`
			NextAt   float64       `json:"next_at"`
			Tiers    []summaryTier `json:"tiers"`
		} `json:"season"`
		History []struct {
			Name          string  `json:"name"`
			Span          string  `json:"span"`
			FinalProgress float64 `json:"final_progress"`
			FinalTier     string  `json:"final_tier"`
		} `json:"history"`
	}
	if raw != nil {
		_ = json.Unmarshal(raw, &sum)
	}
	pct := func(x float64) int { return int(math.Round(x * 100)) }
	if c := sum.Season; c != nil && strings.EqualFold(c.Span, span) {
		return &okrTier{Season: c.Name, Name: c.Tier, Progress: pct(c.Progress), Next: c.NextTier, NextAt: pct(c.NextAt)}
	}
	for i := len(sum.History) - 1; i >= 0; i-- {
		if past := sum.History[i]; strings.EqualFold(past.Span, span) {
			return &okrTier{Season: past.Name, Name: past.FinalTier, Progress: pct(past.FinalProgress), Final: true}
		}
	}
	if !strings.EqualFold(span, quarterSpan(now)) {
		return nil
	}
	tiers := defaultTiers
	if sum.Season != nil && len(sum.Season.Tiers) > 0 {
		tiers = sum.Season.Tiers
	}
	progress, n := 0.0, 0
	for _, o := range all {
		if strings.EqualFold(o.Span, span) {
			progress += o.Progress
			n++
		}
	}
	if n > 0 {
		progress /= float64(n)
	}
	t := &okrTier{Progress: pct(progress), Estimated: true}
	for _, tier := range tiers {
		if progress >= tier.At-1e-9 {
			t.Name = tier.Name
		} else {
			t.Next, t.NextAt = tier.Name, pct(tier.At)
			break
		}
	}
	return t
}

// quarterSpan: the calendar quarter around t as a span, "3M-2026-Q4"
// (okr.quarter_span).
func quarterSpan(t time.Time) string {
	return fmt.Sprintf("3M-%d-Q%d", t.Year(), (int(t.Month())-1)/3+1)
}

func (s *Server) handleOKR(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	all := s.allProjects()
	today := now.Format("2006-01-02")
	var current, later, past, done []okrObjective
	objs := s.objectives(all, now)
	for _, o := range objs {
		x := okrObjective{webObjective: o, AreaLinks: s.areaLinks(o.Areas, o.Rel)}
		for _, kr := range o.KRs {
			k := okrKR{webKR: kr}
			for _, p := range kr.Projects {
				k.Rows = append(k.Rows, s.row(p, nil, nil)) // its key result is the one above it
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
	summary := s.xpSummary()
	for i := range periods {
		if s.cfg.NoXP {
			break
		}
		periods[i].Tier = s.seasonTier(periods[i].Span, objs, summary, now)
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
	// what the review's buttons need (-writable): the line and where it is
	Rel    string
	Lnum   int
	Src    string
	Open   bool   // an open task: tick it
	Cal    bool   // on the calendar: put it on tomorrow
	Dest   string // an inbox line's @project(…)
	DestTo string // the project it names, "rel:lnum"
	Inbox  bool   // a line of inbox.zortex (else marked @project elsewhere)
}

type reviewSpent struct {
	Text    string
	URL     string
	Minutes int
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

// weekNotes: what is written in the week's entry of the reviews note (wins,
// lessons, ...), rendered, and the entry's URL. The focus is left out (the
// page shows its projects), and so are labels with nothing under them and
// the entry's days (its "## <date>" headings).
func (s *Server) weekNotes(week string) (template.HTML, string) {
	d := s.reviewsDoc()
	if d == nil {
		return "", ""
	}
	var head *notes.Node
	d.Tree.Walk(func(n *notes.Node) {
		if head == nil && n.Type == syntax.KindHeading && n.Level == 1 && n.Text == week {
			head = n
		}
	})
	if head == nil {
		return "", ""
	}
	// the entry's own lines: up to its first day
	last := head.End
	for _, c := range head.Children {
		if c.Type == syntax.KindHeading {
			last = c.Start - 1
			break
		}
	}
	blank := func(from, to int) bool {
		for l := from; l <= to && l <= len(d.Lines); l++ {
			if strings.TrimSpace(d.Lines[l-1]) != "" {
				return false
			}
		}
		return true
	}
	skip := map[int]bool{}
	for _, c := range head.Children {
		if c.Type != syntax.KindLabel || c.Start > last {
			continue
		}
		end := c.End
		if end > last {
			end = last
		}
		if strings.EqualFold(c.Text, "Focus") || blank(c.Start+1, end) {
			for l := c.Start; l <= end; l++ {
				skip[l] = true
			}
		}
	}
	// trim blank lines at either end, then render the runs between skips
	first := head.Start + 1
	for first <= last && (skip[first] || strings.TrimSpace(d.Lines[first-1]) == "") {
		first++
	}
	for last >= first && (skip[last] || strings.TrimSpace(d.Lines[last-1]) == "") {
		last--
	}
	if first > last {
		return "", s.noteURL(d.Rel, head.Start)
	}
	r := &noteRenderer{s: s, doc: d, ast: d.Parse()}
	for l := first; l <= last; l++ {
		if skip[l] {
			continue
		}
		end := l
		for end+1 <= last && !skip[end+1] {
			end++
		}
		r.renderRange(l, end)
		l = end
	}
	return template.HTML(r.b.String()), s.noteURL(d.Rel, head.Start)
}

// planWeek: the week a weekly review held on `today` plans: this one, or
// the next from Saturday on (review.next_week_from), as Neovim's.
func planWeek(today time.Time) string {
	if wd := today.Weekday(); wd == time.Saturday || wd == time.Sunday {
		return isoWeek(today.AddDate(0, 0, 7))
	}
	return isoWeek(today)
}

func (s *Server) handleReview(w http.ResponseWriter, r *http.Request) {
	if day := r.URL.Query().Get("day"); day != "" {
		s.handleReviewDay(w, r, day)
		return
	}
	now := time.Now()
	week, monday, sunday := weekBounds(r.URL.Query().Get("week"), now)
	from, to := monday.Format("2006-01-02"), sunday.Format("2006-01-02")
	today := now.Format("2006-01-02")
	soon := now.AddDate(0, 0, 7).Format("2006-01-02")
	all := s.allProjects()
	krs := s.keyResults(all, now)
	// the week the focus and notes go to: the one shown, or on a weekend
	// looking at this week, the next (Neovim's weekly review plans it then)
	plan := week
	if r.URL.Query().Get("week") == "" {
		plan = planWeek(now)
	}

	// inbox: what has no home yet
	inbox := s.reviewInboxItems()

	// focus and the projects without a next action
	planMonday := monday
	if plan != week {
		_, planMonday, _ = weekBounds(plan, now)
	}
	focusWeek, focus, earlier := s.focus(all, planMonday)
	focused := map[*webProject]bool{}
	var focusRows []projectRow
	for _, p := range focus {
		focused[p] = true
		focusRows = append(focusRows, s.row(p, focused, krs))
	}
	var quiet, active []projectRow
	var completed, overdue, dueSoon, putOff []reviewTask
	for _, p := range all {
		pname, purl := p.Name, s.projectURL(p)
		for _, t := range p.Tasks {
			rt := reviewTask{Project: pname, PURL: purl, HTML: t.HTML, Due: t.Due, Done: t.DoneDate, PutOff: t.PutOff, URL: t.URL,
				Rel: p.Rel, Lnum: t.Lnum, Src: t.Line, Open: !t.Done}
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
		if p.Root || p.isDone() {
			continue
		}
		own := 0
		for _, t := range p.Tasks {
			if !t.Done {
				own++
			}
		}
		if own > 0 && !focused[p] {
			active = append(active, s.row(p, focused, krs))
		}
		if len(p.Children) > 0 {
			continue
		}
		if ru := p.rollup(); ru.Open == 0 {
			quiet = append(quiet, s.row(p, focused, krs))
		}
	}
	// the projects to pick the focus from: on key results first, then the
	// most open work
	sort.SliceStable(active, func(i, j int) bool {
		if (len(active[i].KRs) > 0) != (len(active[j].KRs) > 0) {
			return len(active[i].KRs) > 0
		}
		return active[i].Rollup.Open > active[j].Rollup.Open
	})
	if len(active) > 20 {
		active = active[:20]
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
	hasXP = hasXP && !s.cfg.NoXP
	broken := len(s.current().broken)

	notesHTML, notesURL := s.weekNotes(plan)
	labels := []string{"Wins", "Lessons"}
	if d := s.reviewsDoc(); d != nil {
		if from, to, ok := entryRange(d.Lines, plan, ""); ok {
			labels = entryLabels(d.Lines, from, to)
		} else {
			labels = labelsOf(reviewTemplate(d.Lines, "weekly"))
		}
	}

	prev, _, _ := weekBounds("", monday.AddDate(0, 0, -7))
	next, _, _ := weekBounds("", monday.AddDate(0, 0, 7))
	s.render(w, r, "review", http.StatusOK, map[string]any{
		"Title":       "Review · " + week,
		"Scope":       "week",
		"Week":        week,
		"PlanWeek":    plan,
		"FocusWeek":   focusWeek,
		"Active":      active,
		"Writable":    s.cfg.Writable,
		"MoveTargets": s.moveTargets(all),
		"EntryLabels": labels,
		"Range":       monday.Format("Jan 2") + " – " + sunday.Format("Jan 2, 2006"),
		"ThisWeek":    week == isoWeek(now),
		"Prev":        prev,
		"Next":        next,
		"Today":       today,
		"Inbox":       inbox,
		"Focus":       focusRows,
		"Notes":       notesHTML,
		"NotesURL":    notesURL,
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
