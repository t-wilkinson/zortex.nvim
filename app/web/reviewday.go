package web

import (
	"encoding/json"
	"html/template"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The daily review on the web (GET /review?day=today), what Neovim's
// :ZortexReview day finds, with its fixes a tap away (-writable; the POSTs
// are in reviewapi.go):
//
//   - since the last daily review (.z/review_state.json, shared with
//     Neovim; at most a week back): what was completed, how the work served
//     the plan (from Neovim's XP summary)
//   - the inbox: move each line to a project
//   - the week's focus, tasks put off on 2+ days, objectives against the
//     time passed
//   - the calendar's open tasks: tick them, or put them on tomorrow
//   - work finished without an area: give it one; "Finish review" writes
//     @a(<default>) on the rest and marks the day reviewed
//   - overdue and due by tomorrow: tick, or move the date
//   - the day's entry in reviews.zortex, and a line under any of its labels

// reviewState is .z/review_state.json (Neovim's services/agenda): the last
// daily review's day and the first day it covered.
type reviewState struct {
	Version int    `json:"version"`
	LastDay string `json:"last_day,omitempty"`
	From    string `json:"from,omitempty"`
}

func (s *Server) reviewStatePath() string {
	return filepath.Join(s.cfg.Root, ".z", "review_state.json")
}

func (s *Server) readReviewState() reviewState {
	var st reviewState
	if raw, err := os.ReadFile(s.reviewStatePath()); err == nil {
		_ = json.Unmarshal(raw, &st)
	}
	return st
}

func (s *Server) writeReviewState(st reviewState) error {
	st.Version = 1
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	path := s.reviewStatePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(filepath.Dir(path), ".syncthing.review_state.json.tmp")
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func addDays(date string, n int) string {
	t, err := time.Parse("2006-01-02", date)
	if err != nil {
		return date
	}
	return t.AddDate(0, 0, n).Format("2006-01-02")
}

// dayWindow: the first day the daily review on `today` covers: the day after
// the last daily review (the same window again when that was today), at
// most 7 days back (agenda.day_window).
func dayWindow(st reviewState, today string) string {
	earliest := addDays(today, -6)
	from := today
	switch {
	case st.LastDay == today && st.From != "":
		from = st.From
	case st.LastDay != "" && st.LastDay < today:
		from = addDays(st.LastDay, 1)
	}
	if from < earliest {
		from = earliest
	}
	if from > today {
		from = today
	}
	return from
}

// areaWindow: from when the daily review asks about work without an area:
// the last daily review's day (what was finished after it), else `from`.
func areaWindow(st reviewState, today, from string) string {
	if st.LastDay != "" && st.LastDay < from && st.LastDay >= addDays(today, -7) {
		return st.LastDay
	}
	return from
}

// =============================================================================
// Work finished without an area (services/areas/assign)
// =============================================================================

// unassignedItem is a project whose finished tasks have no area (one item,
// its tasks in Tasks), or a finished task outside projects without one.
type unassignedItem struct {
	Kind  string // "project" | "task"
	Rel   string
	Lnum  int
	Src   string // its line, for the edit
	Title string
	HTML  template.HTML
	URL   string
	Date  string // the latest completion
	Count int
	Hours float64
	KR    bool // on a key result (season XP), but no area
	Tasks []unassignedItem
}

// areaResolver says whether @area(…) values name an area of areas.zortex.
type areaResolver struct {
	s      *Server
	byLine map[int]*webArea
	doc    *notes.Document
	memo   map[string]bool
}

func (s *Server) newAreaResolver() *areaResolver {
	_, _, byLine, d := s.areaTree()
	return &areaResolver{s: s, byLine: byLine, doc: d, memo: map[string]bool{}}
}

func (r *areaResolver) any(values []string) bool {
	for _, v := range values {
		for _, part := range strings.Split(v, ",") {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			ok, seen := r.memo[part]
			if !seen {
				ok = r.s.resolveArea(part, r.byLine, r.doc) != nil
				r.memo[part] = ok
			}
			if ok {
				return true
			}
		}
	}
	return false
}

func lineAreas(line string) []string {
	var out []string
	for _, m := range areaAttr.FindAllStringSubmatch(line, -1) {
		out = append(out, m[1])
	}
	return out
}

// unassigned: finished work dated in [from, to] with no area that resolves:
// not its own @a, not its project's (or a parent project's), not the areas
// of the objectives whose key results link its project. Newest first.
func (s *Server) unassigned(all []*webProject, from, to string) []unassignedItem {
	res := s.newAreaResolver()
	// project -> the objectives' areas, through the key results linking it
	// or a project above it (every key result, as the ledger reads them)
	krAreas := map[*webProject][]string{}
	krLinked := map[*webProject]bool{}
	for _, o := range s.objectives(all, time.Now()) {
		for _, kr := range o.KRs {
			for _, p := range kr.Projects {
				krLinked[p] = true
				krAreas[p] = append(krAreas[p], o.Areas...)
			}
		}
	}
	var out []unassignedItem
	ids := map[string]bool{} // project tasks' ids: their calendar copies are them
	for _, p := range all {
		var item *unassignedItem
		var projectAreas, objAreas []string
		onKR := false
		for _, x := range p.lineage() {
			if len(projectAreas) == 0 && len(x.Areas) > 0 {
				projectAreas = x.Areas
			}
			objAreas = append(objAreas, krAreas[x]...)
			onKR = onKR || krLinked[x]
		}
		projectHas := res.any(projectAreas) || res.any(objAreas)
		for _, t := range p.Tasks {
			if t.ID != "" {
				ids[t.ID] = true
			}
			if !t.Done || t.DoneDate < from || t.DoneDate > to || s.ix.IsArchived(p.Rel) {
				continue
			}
			if projectHas || res.any(lineAreas(t.Line)) {
				continue
			}
			ti := unassignedItem{Kind: "task", Rel: p.Rel, Lnum: t.Lnum, Src: t.Line, Title: withoutLinks(t.Line, 0), HTML: t.HTML, URL: t.URL, Date: t.DoneDate, Count: 1, Hours: t.Hours}
			if p.Root {
				out = append(out, ti) // under a note's root: on its own line
				continue
			}
			if item == nil {
				line := ""
				if p.Lnum >= 1 && p.doc != nil && p.Lnum <= len(p.doc.Lines) {
					line = p.doc.Lines[p.Lnum-1]
				}
				item = &unassignedItem{Kind: "project", Rel: p.Rel, Lnum: p.Lnum, Src: line, Title: p.Name, URL: s.projectURL(p), KR: onKR}
			}
			item.Tasks = append(item.Tasks, ti)
			item.Count++
			item.Hours += t.Hours
			if t.DoneDate > item.Date {
				item.Date = t.DoneDate
			}
		}
		if item != nil {
			out = append(out, *item)
		}
	}
	// finished tasks outside projects: the calendar and other notes
	cal := s.calibration()
	for _, rel := range s.ix.All() {
		if s.ix.IsArchived(rel) {
			continue
		}
		d := s.ix.Doc(rel)
		if d == nil || s.isProjectDoc(d) {
			continue
		}
		if h := d.Header(); strings.EqualFold(rel, "okr"+s.cfg.Ext) || syntax.ListHas(h.Names, "OKR") || syntax.ListHas(h.Names, "Objectives") {
			continue
		}
		var groups map[int]*edit.GroupTask
		r := &noteRenderer{s: s, doc: d}
		for i, line := range d.Lines {
			if !strings.Contains(line, "@done(") || d.InCode(i+1) {
				continue
			}
			it := syntax.ItemOf(line)
			if it == nil || (it.Mark != "x" && it.Mark != "X") {
				continue
			}
			date, _ := edit.Attribute(line, "done")
			if date < from || date > to {
				continue
			}
			if id := edit.ID(line); id != "" && ids[id] {
				continue // a copy: its project task counts
			}
			if res.any(lineAreas(line)) {
				continue
			}
			if groups == nil {
				groups = cal.groups(d.Lines, 0, 0)
			}
			hours := cal.hours(attrOrBare(line, "size"))
			if g := groups[i+1]; g != nil {
				if !g.Leaf {
					continue // a group pays through its tasks
				}
				hours = g.Hours
			}
			out = append(out, unassignedItem{Kind: "task", Rel: rel, Lnum: i + 1, Src: line, Title: withoutLinks(line, it.ContentCol),
				HTML: template.HTML(strings.TrimSpace(r.entryHTML(line, i+1, it.ContentCol))), URL: s.noteURL(rel, i+1), Date: date, Count: 1, Hours: hours})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Date != out[j].Date {
			return out[i].Date > out[j].Date
		}
		return out[i].Title < out[j].Title
	})
	return out
}

// =============================================================================
// The page
// =============================================================================

// areaChoice is an area to pick for work without one.
type areaChoice struct {
	Value string
	Label string
}

func (s *Server) areaChoices() (list []areaChoice, defaultOK bool) {
	roots, _, byLine, d := s.areaTree()
	def := s.defaultAreaValue()
	var dflt *webArea
	if def != "" {
		dflt = s.resolveArea(def, byLine, d)
	}
	for _, r := range roots {
		r.walk(func(a *webArea) {
			if a == dflt {
				return
			}
			var names []string
			for x := a; x != nil; x = x.Parent {
				names = append([]string{x.Name}, names...)
			}
			list = append(list, areaChoice{Value: a.Value, Label: strings.Join(names, " › ")})
		})
	}
	return list, dflt != nil
}

// workSplit: how the work done in [from, to] served the plan, from the XP
// summary's daily totals: effort, and the shares on key results, on areas
// only and with no area.
type workSplit struct {
	OK               bool
	Effort, Hours    float64
	KR, Area, None   int // percent
	AreaXP, SeasonXP float64
}

func (s *Server) workIn(from, to string) workSplit {
	var w workSplit
	raw := s.xpSummary()
	if raw == nil || s.cfg.NoXP {
		return w
	}
	var sum struct {
		Days []struct {
			Date   string  `json:"date"`
			XP     float64 `json:"xp"`
			Season float64 `json:"season"`
			Effort float64 `json:"effort"`
			KR     float64 `json:"kr"`
			Area   float64 `json:"area"`
			None   float64 `json:"none"`
		} `json:"days"`
	}
	if json.Unmarshal(raw, &sum) != nil || len(sum.Days) == 0 {
		return w
	}
	var kr, area, none float64
	for _, d := range sum.Days {
		if d.Date >= from && d.Date <= to {
			w.Effort += d.Effort
			w.AreaXP += d.XP
			w.SeasonXP += d.Season
			kr += d.KR
			area += d.Area
			none += d.None
		}
	}
	w.OK = true
	if cal := calibrationOf(raw); cal.XPPerHour > 0 {
		w.Hours = w.Effort / cal.XPPerHour
	}
	if t := kr + area + none; t > 0 {
		w.KR = int(math.Round(kr / t * 100))
		w.Area = int(math.Round(area / t * 100))
		w.None = 100 - w.KR - w.Area
	}
	return w
}

// reviewInboxItems: the inbox's lines, and lines elsewhere marked
// @project(…) (services/triage), with what Move needs.
func (s *Server) reviewInboxItems() []reviewTask {
	var out []reviewTask
	var all []*webProject
	add := func(d *notes.Document, lnum int, line string, col int) {
		rr := &noteRenderer{s: s, doc: d}
		dest, _ := edit.Attribute(line, "project")
		t := reviewTask{HTML: template.HTML(strings.TrimSpace(rr.entryHTML(line, lnum, col))), URL: s.noteURL(d.Rel, lnum),
			Rel: d.Rel, Lnum: lnum, Src: line, Dest: dest, Inbox: d.Rel == inboxRel}
		// where @project(1.4) points ([P/#1.4]): the project Move picks first
		if link := triageLink(dest); link != "" {
			if all == nil {
				all = s.allProjects()
			}
			if res, err := links.ResolveFirst(s.ix, link, links.Options{From: d, Lnum: lnum}); err == nil && res != nil {
				if list := projectsFor(all, res.Doc.Rel, res.Lnum, res.Doc); len(list) > 0 {
					t.DestTo = list[0].Rel + ":" + strconv.Itoa(list[0].Lnum)
				}
			}
		}
		out = append(out, t)
	}
	if d := s.ix.Doc(inboxRel); d != nil {
		for i, line := range d.Lines {
			lnum := i + 1
			if lnum <= d.Header().LastLnum || d.InCode(lnum) || strings.TrimSpace(line) == "" {
				continue
			}
			it := syntax.ItemOf(line)
			if it != nil && (it.Mark == "x" || it.Mark == "X") {
				continue
			}
			// a nested line goes with the line above it
			if strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
				continue
			}
			col := 0
			if it != nil {
				col = it.ContentCol
			}
			add(d, lnum, line, col)
		}
	}
	for _, rel := range s.ix.All() {
		if rel == inboxRel || s.ix.IsArchived(rel) {
			continue
		}
		d := s.ix.Doc(rel)
		if d == nil {
			continue
		}
		for i, line := range d.Lines {
			if !strings.Contains(line, "@project(") || d.InCode(i+1) {
				continue
			}
			it := syntax.ItemOf(line)
			if it != nil && (it.Mark == "x" || it.Mark == "X" || it.Mark == edit.Moved) {
				continue
			}
			col := 0
			if it != nil {
				col = it.ContentCol
			}
			add(d, i+1, line, col)
		}
	}
	return out
}

// triageLink: the link a @project(…) value names (services/triage link()):
// "1.4" -> "[P/#1.4]", "1/1.4" -> "[P/#1/#1.4]", "P/#Kitchen" as written.
func triageLink(value string) string {
	value = strings.TrimSpace(value)
	switch {
	case value == "":
		return ""
	case strings.HasPrefix(value, "["):
		return value
	case strings.Contains(value, "#") || strings.HasPrefix(value, "@"):
		return "[" + value + "]"
	}
	var parts []string
	for _, p := range strings.Split(value, "/") {
		if p = strings.TrimSpace(p); p != "" {
			parts = append(parts, "#"+p)
		}
	}
	return "[P/" + strings.Join(parts, "/") + "]"
}

// moveTargets: the active projects to move an inbox line to.
func (s *Server) moveTargets(all []*webProject) []areaChoice {
	var out []areaChoice
	for _, p := range all {
		if p.Root || p.isDone() {
			continue
		}
		label := strings.Join(p.Path, " › ")
		if !s.isProjectsNote(p.doc) {
			label = p.doc.Name() + " › " + label
		}
		out = append(out, areaChoice{Value: p.Rel + ":" + strconv.Itoa(p.Lnum), Label: label})
	}
	return out
}

func (s *Server) handleReviewDay(w http.ResponseWriter, r *http.Request, dayParam string) {
	now := time.Now()
	today := now.Format("2006-01-02")
	date := today
	if dayParam != "" && dayParam != "today" {
		if t, err := time.Parse("2006-01-02", dayParam); err == nil {
			date = t.Format("2006-01-02")
		}
	}
	st := s.readReviewState()
	from := dayWindow(st, date)
	areaFrom := areaWindow(st, date, from)
	tomorrow := addDays(date, 1)
	all := s.allProjects()
	krs := s.keyResults(all, now)

	// project tasks: done in the window, overdue, due by tomorrow, put off
	var completed, overdue, dueSoon, putOff []reviewTask
	for _, p := range all {
		pname, purl := p.Name, s.projectURL(p)
		for _, t := range p.Tasks {
			rt := reviewTask{Project: pname, PURL: purl, HTML: t.HTML, Due: t.Due, Done: t.DoneDate, PutOff: t.PutOff, URL: t.URL,
				Rel: p.Rel, Lnum: t.Lnum, Src: t.Line, Open: !t.Done}
			switch {
			case t.Done:
				if t.DoneDate >= from && t.DoneDate <= date {
					completed = append(completed, rt)
				}
			case t.Due != "" && t.Due < date:
				overdue = append(overdue, rt)
			case t.Due != "" && t.Due <= tomorrow:
				dueSoon = append(dueSoon, rt)
			}
			if !t.Done && t.PutOff >= 2 {
				putOff = append(putOff, rt)
			}
		}
	}

	// the calendar in the window: its tasks done, and the open ones (a copy
	// of a project task is counted with its project, above)
	projectIDs := map[string]bool{}
	for _, p := range all {
		for _, t := range p.Tasks {
			if t.ID != "" {
				projectIDs[t.ID] = true
			}
		}
	}
	var open []reviewTask
	calTasks, calDone := 0, 0
	if doc := s.calendarDoc(); doc != nil {
		rr := &noteRenderer{s: s, doc: doc}
		days := calendarEntries(doc, from, date)
		var dates []string
		for d := range days {
			dates = append(dates, d)
		}
		sort.Strings(dates)
		for _, d := range dates {
			for _, e := range days[d] {
				line := doc.Lines[e.Lnum-1]
				if !e.Task || e.Moved {
					continue
				}
				calTasks++
				if e.Done {
					calDone++
					if done, _ := edit.Attribute(line, "done"); !projectIDs[edit.ID(line)] && e.Ref == "" && (done == "" || (done >= from && done <= date)) {
						completed = append(completed, reviewTask{Project: "calendar", PURL: s.noteURL(doc.Rel, e.Lnum), HTML: template.HTML(strings.TrimSpace(rr.entryHTML(line, e.Lnum, e.textCol))),
							Done: d, URL: s.noteURL(doc.Rel, e.Lnum), Rel: doc.Rel, Lnum: e.Lnum, Src: line})
					}
					continue
				}
				open = append(open, reviewTask{Project: d, PURL: s.noteURL(doc.Rel, e.Lnum), HTML: template.HTML(strings.TrimSpace(rr.entryHTML(line, e.Lnum, e.textCol))),
					URL: s.noteURL(doc.Rel, e.Lnum), Rel: doc.Rel, Lnum: e.Lnum, Src: line, Open: true, Cal: true})
				if d < date {
					overdue = append(overdue, reviewTask{Project: "calendar " + d, PURL: s.noteURL(doc.Rel, e.Lnum), HTML: template.HTML(strings.TrimSpace(rr.entryHTML(line, e.Lnum, e.textCol))),
						URL: s.noteURL(doc.Rel, e.Lnum), Rel: doc.Rel, Lnum: e.Lnum, Src: line, Open: true, Cal: true})
				}
			}
		}
	}
	sort.SliceStable(completed, func(i, j int) bool { return completed[i].Done > completed[j].Done })
	sort.SliceStable(overdue, func(i, j int) bool { return overdue[i].Due < overdue[j].Due })
	sort.SliceStable(dueSoon, func(i, j int) bool { return dueSoon[i].Due < dueSoon[j].Due })
	sort.SliceStable(putOff, func(i, j int) bool { return putOff[i].PutOff > putOff[j].PutOff })

	// objectives running now, the furthest behind first
	var objectives []*webObjective
	for _, o := range s.objectives(all, now) {
		if o.Done != "" || o.Start.Format("2006-01-02") > date || o.End.Format("2006-01-02") < date {
			continue
		}
		objectives = append(objectives, o)
	}
	sort.SliceStable(objectives, func(i, j int) bool {
		return objectives[i].Elapsed-objectives[i].Progress > objectives[j].Elapsed-objectives[j].Progress
	})

	// the week's focus
	dt, _ := time.ParseInLocation("2006-01-02", date, now.Location())
	week := isoWeek(dt)
	focusWeek, focus, earlier := s.focus(all, dt)
	focused := map[*webProject]bool{}
	for _, p := range focus {
		focused[p] = true
	}
	var focusRows []projectRow
	for _, p := range focus {
		focusRows = append(focusRows, s.row(p, focused, krs))
	}

	unassigned := s.unassigned(all, areaFrom, date)
	choices, defaultOK := s.areaChoices()
	spent, spentTotal := s.timeSpentIn(from, date)
	if len(spent) > 10 {
		spent = spent[:10]
	}
	entry, entryURL, labels := s.dayEntry(week, date)

	since := "today"
	if from != date {
		since = "since " + from
	}
	s.render(w, r, "review", http.StatusOK, map[string]any{
		"Title":       "Daily review · " + date,
		"Scope":       "day",
		"Date":        date,
		"Week":        week,
		"Today":       today,
		"IsToday":     date == today,
		"Prev":        addDays(date, -1),
		"Next":        addDays(date, 1),
		"From":        from,
		"AreaFrom":    areaFrom,
		"Since":       since,
		"LastDay":     st.LastDay,
		"Reviewed":    st.LastDay == date,
		"Writable":    s.cfg.Writable,
		"Inbox":       s.reviewInboxItems(),
		"MoveTargets": s.moveTargets(all),
		"Focus":       focusRows,
		"FocusWeek":   focusWeek,
		"Earlier":     earlier,
		"PutOff":      putOff,
		"Objectives":  objectives,
		"Completed":   completed,
		"CalTasks":    calTasks,
		"CalDone":     calDone,
		"Open":        open,
		"Unassigned":  unassigned,
		"Areas":       choices,
		"DefaultArea": s.defaultAreaValue(),
		"DefaultOK":   defaultOK,
		"Overdue":     overdue,
		"DueSoon":     dueSoon,
		"Spent":       spent,
		"SpentTotal":  spentTotal,
		"Work":        s.workIn(from, date),
		"HasXP":       !s.cfg.NoXP,
		"Entry":       entry,
		"EntryURL":    entryURL,
		"EntryLabels": labels,
		"BrokenLinks": len(s.current().broken),
	})
}

// dayEntry: the day's entry in reviews.zortex, rendered, its URL and its
// labels (the template's when the entry doesn't exist yet).
func (s *Server) dayEntry(week, date string) (template.HTML, string, []string) {
	d := s.reviewsDoc()
	if d == nil {
		return "", "", defaultDayTemplateLabels()
	}
	from, to, ok := entryRange(d.Lines, week, date)
	if !ok {
		return "", "", labelsOf(reviewTemplate(d.Lines, "daily"))
	}
	labels := entryLabels(d.Lines, from, to)
	first, last := from, to
	for first <= last && strings.TrimSpace(d.Lines[first-1]) == "" {
		first++
	}
	for last >= first && strings.TrimSpace(d.Lines[last-1]) == "" {
		last--
	}
	url := s.noteURL(d.Rel, from-1)
	if first > last {
		return "", url, labels
	}
	r := &noteRenderer{s: s, doc: d, ast: d.Parse()}
	r.renderRange(first, last)
	return template.HTML(r.b.String()), url, labels
}

func labelsOf(lines []string) []string {
	var out []string
	for _, l := range lines {
		if syntax.Classify(l).Kind == syntax.KindLabel {
			name := strings.TrimSuffix(strings.TrimSpace(l), ":")
			if !strings.EqualFold(name, "focus") {
				out = append(out, name)
			}
		}
	}
	return out
}

func defaultDayTemplateLabels() []string { return labelsOf(defaultDayTemplate) }
