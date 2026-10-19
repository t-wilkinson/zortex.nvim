package web

import (
	"encoding/json"
	"fmt"
	"html/template"
	"math"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Projects on the web, read the way the plugin reads them
// (lua/zortex/services/projects): the headings of the Projects note and of
// notes tagged @P are projects, the note itself the root; a project's tasks
// are the checkbox items from its heading to its first sub-project.
//
//	GET  /projects               this week's focus, then every project with open work
//	GET  /project?rel=&lnum=     one project: progress, next tasks (put off,
//	                             planned), sub-projects, the key results it
//	                             moves, its log, calendar days, time spent,
//	                             the notes and files it links and that link it
//	POST /api/project/log        {rel, lnum, expect, text}: add a dated line
//	                             under the project's "Log:" label (-writable)
//
// Progress weighs tasks by their @size hours (Neovim's calibration from the
// XP summary), and a task is done when it, or a calendar copy with its @id,
// is checked (services/mirrors).

// webTask is a project task.
type webTask struct {
	Lnum     int
	Line     string
	HTML     template.HTML
	Done     bool
	OnCal    bool // done through a calendar copy
	ID       string
	Size     string
	Hours    float64 // its hours, or its share of its group's (edit.Groups)
	Group    string  // the group it is in: the task it is nested under
	Due      string
	DoneDate string
	Spent    int // minutes: its @spent and its calendar copies'
	PutOff   int // earlier days it was on the calendar and not done
	Planned  string
	URL      string
}

// webProject is a project: a heading of a project note, or the note itself.
type webProject struct {
	Rel                   string
	Lnum, End, OwnEnd     int // heading, last line of its subtree, last line before its first sub-project
	Name, Link            string
	Path                  []string
	Root                  bool
	Parent                *webProject
	Children              []*webProject
	Tasks                 []*webTask
	Size, P, I, Due, Done string
	Areas                 []string // @a(...) values
	doc                   *notes.Document
	node                  *notes.Node // its heading (the article for a note's root)
}

// rollup is a project's tasks with its sub-projects': counts and hours.
type rollup struct {
	Total, DoneN, Open int
	Hours, DoneHours   float64
}

func (r rollup) Completion() float64 {
	if r.Hours <= 0 {
		return 0
	}
	return r.DoneHours / r.Hours
}

func (r rollup) Percent() int { return int(math.Round(r.Completion() * 100)) }

func (p *webProject) rollup() rollup {
	var r rollup
	p.walk(func(x *webProject) {
		for _, t := range x.Tasks {
			r.Total++
			r.Hours += t.Hours
			if t.Done {
				r.DoneN++
				r.DoneHours += t.Hours
			} else {
				r.Open++
			}
		}
	})
	return r
}

func (p *webProject) walk(fn func(*webProject)) {
	fn(p)
	for _, c := range p.Children {
		c.walk(fn)
	}
}

func (p *webProject) contains(rel string, lnum int) bool {
	return p.Rel == rel && lnum >= p.Lnum && lnum <= p.End
}

func (p *webProject) isDone() bool { return p.Done != "" }

// ancestors: the project, then its parents outward.
func (p *webProject) lineage() []*webProject {
	var out []*webProject
	for x := p; x != nil; x = x.Parent {
		out = append(out, x)
	}
	return out
}

var (
	areaAttr     = regexp.MustCompile(`@(?:a|area)\(([^)]*)\)`)
	objectiveRe  = regexp.MustCompile(`^(\w+)-(\d{4})-(\w+)\s+(.+)$`)
	weekHeading  = regexp.MustCompile(`^\d{4}-W\d{2}$`)
	keyResultKey = regexp.MustCompile(`^KR\d*$`)
)

// attrOrBare: @key(value), else the bare form (@lg, @p1).
func attrOrBare(line, key string) string {
	if v, ok := edit.Attribute(line, key); ok {
		return v
	}
	switch key {
	case "size":
		return bareSize(line)
	case "p", "i":
		return bareFlag(line, key)
	}
	return ""
}

// projectDocs: the Projects note and @P notes (archives left out), the
// Projects note first.
func (s *Server) projectDocs() []*notes.Document {
	var out []*notes.Document
	for _, rel := range s.ix.All() {
		if s.ix.IsArchived(rel) {
			continue
		}
		if d := s.ix.Doc(rel); d != nil && s.isProjectDoc(d) {
			out = append(out, d)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		pi, pj := s.isProjectsNote(out[i]), s.isProjectsNote(out[j])
		if pi != pj {
			return pi
		}
		return out[i].Rel < out[j].Rel
	})
	return out
}

// isProjectsNote: projects.zortex or the note named P (its links are [P/#…]);
// other @P notes are linked by name ([P/Flipping/#…]).
func (s *Server) isProjectsNote(d *notes.Document) bool {
	return strings.EqualFold(d.Rel, "projects"+s.cfg.Ext) || syntax.ListHas(d.Header().Names, "P")
}

// buildProjects: the project tree of one note.
func (s *Server) buildProjects(d *notes.Document, cal calibration, hist *calendarHistory, today string) *webProject {
	projectsNote := s.isProjectsNote(d)
	root := &webProject{Rel: d.Rel, Lnum: 1, End: len(d.Lines), Name: d.Name(), Root: true, doc: d}
	var article *notes.Node
	for _, n := range d.Tree.Children {
		if n.Type == syntax.KindArticle {
			article = n
			root.Lnum = n.Start
			break
		}
	}
	if projectsNote {
		root.Link = "[P]"
	} else {
		root.Link = "[P/" + root.Name + "]"
	}
	// organizational headings aren't projects but still name the ones under
	// them: path is the headings down to here, projects or not
	isProject := s.projectHeadings(d)
	var visit func(n *notes.Node, parent *webProject, path []string)
	visit = func(n *notes.Node, parent *webProject, path []string) {
		for _, c := range n.Children {
			if c.Type != syntax.KindHeading {
				visit(c, parent, path)
				continue
			}
			here := append(append([]string(nil), path...), c.Text)
			if !isProject(c) {
				visit(c, parent, here)
				continue
			}
			p := &webProject{Rel: d.Rel, Lnum: c.Start, End: c.End, Name: c.Text, Parent: parent, doc: d, node: c}
			p.Path = here
			parts := make([]string, len(p.Path))
			for i, t := range p.Path {
				parts[i] = "#" + t
			}
			if projectsNote {
				p.Link = "[P/" + strings.Join(parts, "/") + "]"
			} else {
				p.Link = "[P/" + root.Name + "/" + strings.Join(parts, "/") + "]"
			}
			parent.Children = append(parent.Children, p)
			visit(c, p, here)
		}
	}
	if article != nil {
		root.node = article
		visit(article, root, nil)
	}
	// headings outside the article (a note without a header)
	for _, n := range d.Tree.Children {
		if n != article && n.Type == syntax.KindHeading {
			visit(&notes.Node{Children: []*notes.Node{n}}, root, nil)
		}
	}
	r := &noteRenderer{s: s, doc: d}
	root.walk(func(p *webProject) {
		line := d.Lines[p.Lnum-1]
		// its own lines: up to its first sub-heading, a project or not
		p.OwnEnd = p.End
		if p.node != nil {
			p.OwnEnd = ownEnd(p.node)
		} else if first := firstHeading(d); first > 0 && first <= p.End {
			p.OwnEnd = first - 1
		}
		if !p.Root {
			p.Size, p.P, p.I = attrOrBare(line, "size"), attrOrBare(line, "p"), attrOrBare(line, "i")
			p.Due, _ = edit.Attribute(line, "due")
			p.Done, _ = edit.Attribute(line, "done")
			for _, m := range areaAttr.FindAllStringSubmatch(line, -1) {
				p.Areas = append(p.Areas, m[1])
			}
		}
		// tasks nested under a task: the group shares its size, and counts
		// through its tasks (edit.Groups; services/task_groups)
		groups := cal.groups(d.Lines, p.Lnum+1, p.OwnEnd)
		for l := p.Lnum + 1; l <= p.OwnEnd; l++ {
			if d.InCode(l) {
				continue
			}
			text := d.Lines[l-1]
			it := syntax.ItemOf(text)
			if it == nil || it.Mark == "" || it.Mark == edit.Moved {
				continue
			}
			g := groups[l]
			if g != nil && !g.Leaf {
				continue // a group: its tasks are listed
			}
			t := &webTask{Lnum: l, Line: text, Done: isDone(text), URL: s.noteURL(d.Rel, l)}
			t.HTML = template.HTML(strings.TrimSpace(r.entryHTML(text, l, it.ContentCol)))
			t.ID = edit.ID(text)
			t.Size = attrOrBare(text, "size")
			t.Hours = cal.hours(t.Size)
			if g != nil {
				t.Hours = g.Hours
				if g.Parent != 0 {
					t.Group = groupTitle(d.Lines[g.Parent-1])
				}
				if g.DoneEffective && !t.Done { // under a checked group
					t.Done = true
				}
			}
			t.Due, _ = edit.Attribute(text, "due")
			t.DoneDate, _ = edit.Attribute(text, "done")
			if t.DoneDate == "" && g != nil {
				t.DoneDate = g.DoneDate
			}
			if v, ok := edit.Attribute(text, "spent"); ok {
				if m, ok := parseMinutes(v); ok {
					t.Spent = int(m)
				}
			}
			if h := hist.byID[t.ID]; t.ID != "" && h != nil {
				t.Spent += h.spent
				if !t.Done && h.done {
					t.Done, t.OnCal = true, true
					if t.DoneDate == "" {
						t.DoneDate = h.doneDate
					}
				}
				if !t.Done {
					t.PutOff = h.putOff(today)
					t.Planned = h.planned(today)
				}
			}
			p.Tasks = append(p.Tasks, t)
		}
	})
	return root
}

// allProjects: every project, roots and all, in note order (pre-order).
func (s *Server) allProjects() []*webProject {
	cal := s.calibration()
	hist := s.calendarHistory()
	today := time.Now().Format("2006-01-02")
	var out []*webProject
	for _, d := range s.projectDocs() {
		s.buildProjects(d, cal, hist, today).walk(func(p *webProject) { out = append(out, p) })
	}
	return out
}

// =============================================================================
// Organizational headings (lua/zortex/services/projects/project.lua)
// =============================================================================

// A heading with no task of its own (done or not) and no project attribute
// only groups the projects under it: it isn't a project, unless something
// links it (from outside it) and it has projects under it. Bare tags (for
// @[...] tag links) and the derived @progress don't make one.
var (
	projectAttrRe = regexp.MustCompile(`@(?:size|p|i|due|done|xp|dur|est|a|area)\(`)
	projectBareRe = regexp.MustCompile(`(?:^|\s)@(?:xs|sm|md|lg|xl|epic|legendary|mythic|ultimate|[pi][1-3]|someday|\d+(?:\.\d+)?(?:h|m|min|d|w)(?:\d+m)?)(?:\s|$)`)
)

// ownEnd: the last line of a section's own content, before its first
// sub-heading.
func ownEnd(n *notes.Node) int {
	for _, c := range n.Children {
		if c.Type == syntax.KindHeading {
			return c.Start - 1
		}
	}
	return n.End
}

// firstHeading: the line of a note's first heading, 0 when it has none.
func firstHeading(d *notes.Document) int {
	first := 0
	d.Tree.Walk(func(n *notes.Node) {
		if n.Type == syntax.KindHeading && (first == 0 || n.Start < first) {
			first = n.Start
		}
	})
	return first
}

// projectHeadings: which headings of a project note are projects.
func (s *Server) projectHeadings(d *notes.Document) func(*notes.Node) bool {
	// the links pointing at its lines: from other notes (not archived ones,
	// as the plugin's link index) and from itself
	type ref struct {
		from string
		lnum int
	}
	linked := map[int][]ref{}
	if snap := s.current(); snap != nil {
		for _, b := range snap.backlinks[d.Rel] {
			if b.FromNote && !s.ix.IsArchived(b.From) {
				linked[b.ToLnum] = append(linked[b.ToLnum], ref{b.From, b.Lnum})
			}
		}
		for _, b := range snap.inner[d.Rel] {
			linked[b.ToLnum] = append(linked[b.ToLnum], ref{b.From, b.Lnum})
		}
	}
	memo := map[*notes.Node]bool{}
	var is func(n *notes.Node) bool
	var under func(n *notes.Node) bool
	under = func(n *notes.Node) bool {
		for _, c := range n.Children {
			if c.Type == syntax.KindHeading && is(c) || under(c) {
				return true
			}
		}
		return false
	}
	is = func(n *notes.Node) bool {
		if v, ok := memo[n]; ok {
			return v
		}
		yes := false
		line := d.Lines[n.Start-1]
		if projectAttrRe.MatchString(line) || projectBareRe.MatchString(line) {
			yes = true
		}
		for l := n.Start + 1; !yes && l <= ownEnd(n); l++ {
			if d.InCode(l) {
				continue
			}
			if it := syntax.ItemOf(d.Lines[l-1]); it != nil && it.Mark != "" {
				yes = true
			}
		}
		if !yes {
			for _, r := range linked[n.Start] {
				if r.from != d.Rel || r.lnum < n.Start || r.lnum > n.End {
					yes = under(n)
					break
				}
			}
		}
		memo[n] = yes
		return yes
	}
	return is
}

// projectsFor: the projects a link's target stands for: the project its
// line is in; none for an organizational heading (nothing under it is a
// project, or only links from inside it name it), else the outermost
// projects under it.
func projectsFor(all []*webProject, rel string, lnum int, d *notes.Document) []*webProject {
	if d != nil {
		if n := d.NodeStartingAt(lnum); n != nil && n.Type == syntax.KindHeading {
			isProject := false
			for _, p := range all {
				if p.Rel == rel && p.Lnum == lnum && !p.Root {
					isProject = true
				}
			}
			if !isProject {
				var out []*webProject
				for _, p := range all {
					if p.Rel == rel && p.Lnum > n.Start && p.Lnum <= n.End && (p.Parent == nil || p.Parent.Lnum < n.Start || p.Parent.Root) {
						out = append(out, p)
					}
				}
				return out
			}
		}
	}
	if p := projectAt(all, rel, lnum); p != nil {
		return []*webProject{p}
	}
	return nil
}

// projectAt: the innermost project containing rel:lnum.
func projectAt(all []*webProject, rel string, lnum int) *webProject {
	var best *webProject
	for _, p := range all {
		if p.contains(rel, lnum) && (best == nil || p.Lnum >= best.Lnum) {
			best = p
		}
	}
	return best
}

// =============================================================================
// The calendar's side: copies by @id, the days each was planned
// =============================================================================

type idDay struct {
	date string
	mark string
	lnum int
}

type idHistory struct {
	days     []idDay
	spent    int
	done     bool
	doneDate string
}

// putOff: earlier days (before today) it was on the calendar and not done:
// carried on ([>]) or left open (services/mirrors.copies).
func (h *idHistory) putOff(today string) int {
	seen := map[string]bool{}
	for _, d := range h.days {
		if d.date != "" && d.date < today && (d.mark == " " || d.mark == edit.Moved) {
			seen[d.date] = true
		}
	}
	return len(seen)
}

// planned: the latest day (today or later) it is on, open; "" when none.
func (h *idHistory) planned(today string) string {
	out := ""
	for _, d := range h.days {
		if d.mark == " " && d.date >= today && d.date > out {
			out = d.date
		}
	}
	return out
}

type calendarHistory struct {
	rel    string
	byID   map[string]*idHistory
	dateOf []string // per line (0-based): the day it is under
}

// calendarHistory reads the calendar once per request.
func (s *Server) calendarHistory() *calendarHistory {
	h := &calendarHistory{byID: map[string]*idHistory{}}
	doc := s.calendarDoc()
	if doc == nil {
		return h
	}
	h.rel = doc.Rel
	h.dateOf = make([]string, len(doc.Lines))
	date := ""
	for i, line := range doc.Lines {
		if doc.InCode(i + 1) {
			h.dateOf[i] = date
			continue
		}
		if d, ok := edit.DateHeading(line); ok {
			date = d
		}
		h.dateOf[i] = date
		id := edit.ID(line)
		it := syntax.ItemOf(line)
		if id == "" || it == nil || it.Mark == "" {
			continue
		}
		x := h.byID[id]
		if x == nil {
			x = &idHistory{}
			h.byID[id] = x
		}
		x.days = append(x.days, idDay{date: date, mark: it.Mark, lnum: i + 1})
		if v, ok := edit.Attribute(line, "spent"); ok {
			if m, ok := parseMinutes(v); ok {
				x.spent += int(m)
			}
		}
		if isDone(line) {
			x.done = true
			if d, ok := edit.Attribute(line, "done"); ok && (x.doneDate == "" || d < x.doneDate) {
				x.doneDate = d
			}
		}
	}
	return h
}

// =============================================================================
// Key results and objectives (lua/zortex/services/okr)
// =============================================================================

type webKR struct {
	ID, Text  string
	HTML      template.HTML
	Done      bool
	Progress  float64
	Lag       float64
	Objective string
	Projects  []*webProject
	URL       string
}

func (k webKR) Percent() int    { return int(math.Round(k.Progress * 100)) }
func (k webKR) LagPercent() int { return int(math.Round(k.Lag * 100)) }

// objectiveWindow: the dates "3M-2026-Q4" covers (okr/objective.window).
func objectiveWindow(span string, year int, period string) (time.Time, time.Time) {
	month, length := 1, 12
	p := strings.ToUpper(period)
	switch {
	case len(p) == 2 && p[0] == 'Q' && p[1] >= '1' && p[1] <= '4':
		month, length = int(p[1]-'0')*3-2, 3
	case p == "H1" || p == "H2":
		month, length = 1, 6
		if p == "H2" {
			month = 7
		}
	default:
		m := strings.TrimPrefix(p, "M")
		if n, err := strconv.Atoi(m); err == nil && len(m) <= 2 && n >= 1 && n <= 12 {
			month, length = n, 1
		}
	}
	sp := strings.ToUpper(span)
	if len(sp) > 0 && strings.ContainsRune("MQYH", rune(sp[len(sp)-1])) {
		n := 1
		if len(sp) > 1 {
			v, err := strconv.Atoi(sp[:len(sp)-1])
			if err != nil {
				goto done
			}
			n = v
		}
		switch sp[len(sp)-1] {
		case 'M':
			length = n
		case 'Q':
			length = n * 3
		case 'H':
			length = n * 6
		case 'Y':
			length = n * 12
		}
	}
done:
	start := time.Date(year, time.Month(month), 1, 12, 0, 0, 0, time.Local)
	end := time.Date(year, time.Month(month+length), 0, 12, 0, 0, 0, time.Local)
	return start, end
}

// elapsed: the share of [start, end] (whole days) passed by today.
func elapsed(start, end, today time.Time) float64 {
	day := func(t time.Time) float64 {
		return float64(time.Date(t.Year(), t.Month(), t.Day(), 12, 0, 0, 0, time.UTC).Unix()) / 86400
	}
	total := day(end) - day(start) + 1
	done := day(today) - day(start) + 1
	return math.Max(0, math.Min(1, done/total))
}

func (s *Server) okrDocs() []*notes.Document {
	var out []*notes.Document
	for _, rel := range s.ix.All() {
		if s.ix.IsArchived(rel) {
			continue
		}
		d := s.ix.Doc(rel)
		if d == nil {
			continue
		}
		h := d.Header()
		if strings.EqualFold(rel, "okr"+s.cfg.Ext) || syntax.ListHas(h.Names, "OKR") || syntax.ListHas(h.Names, "Objectives") {
			out = append(out, d)
		}
	}
	return out
}

// webObjective is an objective heading ("## 3M-2026-Q4 Title") and its key
// results (lua/zortex/services/okr/objective).
type webObjective struct {
	Rel        string
	Lnum       int
	Title      string
	Span       string // "3M-2026-Q4"
	Start, End time.Time
	Done       string // its @done date
	Areas      []string
	P          string
	KRs        []webKR
	Progress   float64 // the mean of its key results' (1 when done)
	Elapsed    float64 // the share of its window passed
	URL        string
}

func (o *webObjective) Percent() int        { return int(math.Round(o.Progress * 100)) }
func (o *webObjective) ElapsedPercent() int { return int(math.Round(o.Elapsed * 100)) }

// Behind: more of its window gone than progress made, by more than a tenth.
func (o *webObjective) Behind() bool { return o.Done == "" && o.Elapsed-o.Progress > 0.1 }

// Window: "Oct 1 – Dec 31, 2026".
func (o *webObjective) Window() string {
	if o.Start.Year() != o.End.Year() {
		return o.Start.Format("Jan 2, 2006") + " – " + o.End.Format("Jan 2, 2006")
	}
	return o.Start.Format("Jan 2") + " – " + o.End.Format("Jan 2, 2006")
}

// objectives: every objective of the OKR notes, in note order, with its key
// results (the projects they link, their progress against its window).
func (s *Server) objectives(all []*webProject, now time.Time) []*webObjective {
	var out []*webObjective
	for _, d := range s.okrDocs() {
		r := &noteRenderer{s: s, doc: d}
		byStart := map[int]*webObjective{}
		for _, n := range d.Sections() {
			if n.Type != syntax.KindHeading {
				continue
			}
			m := objectiveRe.FindStringSubmatch(n.Text)
			if m == nil {
				continue
			}
			line := d.Lines[n.Start-1]
			year, _ := strconv.Atoi(m[2])
			o := &webObjective{Rel: d.Rel, Lnum: n.Start, Title: m[4], Span: m[1] + "-" + m[2] + "-" + m[3], URL: s.noteURL(d.Rel, n.Start)}
			o.Start, o.End = objectiveWindow(m[1], year, m[3])
			o.Done, _ = edit.Attribute(line, "done")
			o.P = attrOrBare(line, "p")
			for _, key := range []string{"a", "area"} {
				if v, ok := edit.Attribute(line, key); ok {
					for _, a := range strings.Split(v, ",") {
						if a = strings.TrimSpace(a); a != "" {
							o.Areas = append(o.Areas, a)
						}
					}
				}
			}
			o.Elapsed = elapsed(o.Start, o.End, now)
			byStart[n.Start] = o
			out = append(out, o)
		}
		for i, line := range d.Lines {
			lnum := i + 1
			it := syntax.ItemOf(line)
			if it == nil || !keyResultKey.MatchString(it.Key) || d.InCode(lnum) {
				continue
			}
			// the objective heading it is under
			var o *webObjective
			for n := d.NodeAt(lnum); n != nil && !n.IsRoot() && o == nil; n = n.Parent {
				o = byStart[n.Start]
			}
			if o == nil {
				continue
			}
			kr := webKR{ID: it.Key, Done: it.Mark == "x" || it.Mark == "X", Objective: o.Title, URL: s.noteURL(d.Rel, lnum)}
			from := it.ContentCol
			kr.HTML = template.HTML(strings.TrimSpace(r.entryHTML(line, lnum, from)))
			kr.Text = withoutLinks(line, from)
			seen := map[*webProject]bool{}
			for _, sp := range links.LinksOn(line) {
				res, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: d, Lnum: lnum})
				if err != nil || res == nil {
					continue
				}
				for _, p := range projectsFor(all, res.Doc.Rel, res.Lnum, res.Doc) {
					if !seen[p] {
						seen[p] = true
						kr.Projects = append(kr.Projects, p)
					}
				}
			}
			if kr.Done {
				kr.Progress = 1
			} else {
				var hours, doneH float64
				for _, p := range kr.Projects {
					ru := p.rollup()
					hours += ru.Hours
					doneH += ru.DoneHours
				}
				if hours > 0 {
					kr.Progress = doneH / hours
				}
				kr.Lag = math.Max(0, o.Elapsed-kr.Progress)
			}
			o.KRs = append(o.KRs, kr)
		}
		for _, o := range byStart {
			switch {
			case o.Done != "":
				o.Progress = 1
			case len(o.KRs) > 0:
				sum := 0.0
				for _, kr := range o.KRs {
					sum += kr.Progress
				}
				o.Progress = sum / float64(len(o.KRs))
			}
		}
	}
	return out
}

// keyResults: every key result of an open objective, with the projects it
// links and its progress (their hours done) against its objective's window.
func (s *Server) keyResults(all []*webProject, now time.Time) []webKR {
	var out []webKR
	for _, o := range s.objectives(all, now) {
		if o.Done == "" { // a finished objective moves nothing
			out = append(out, o.KRs...)
		}
	}
	return out
}

// =============================================================================
// The week's focus (lua/zortex/services/review)
// =============================================================================

func isoWeek(t time.Time) string {
	y, w := t.ISOWeek()
	return fmt.Sprintf("%d-W%02d", y, w)
}

func (s *Server) reviewsDoc() *notes.Document {
	if d := s.ix.Doc("reviews" + s.cfg.Ext); d != nil {
		return d
	}
	for _, rel := range s.ix.Catalog().WithName("Reviews") {
		if d := s.ix.Doc(rel); d != nil && !s.ix.IsArchived(rel) {
			return d
		}
	}
	return nil
}

// focus: the projects under "Focus:" in this week's entry of the reviews
// note, or the latest earlier week's when this one has none.
func (s *Server) focus(all []*webProject, now time.Time) (week string, list []*webProject, earlier bool) {
	d := s.reviewsDoc()
	if d == nil {
		return "", nil, false
	}
	want := isoWeek(now)
	type entry struct {
		week     string
		projects []*webProject
	}
	var weeks []entry
	d.Tree.Walk(func(n *notes.Node) {
		if n.Type != syntax.KindHeading || n.Level != 1 || !weekHeading.MatchString(n.Text) {
			return
		}
		e := entry{week: n.Text}
		seen := map[*webProject]bool{}
		for _, c := range n.Children {
			if c.Type != syntax.KindLabel || !strings.EqualFold(c.Text, "Focus") {
				continue
			}
			for l := c.Start + 1; l <= c.End; l++ {
				for _, sp := range links.LinksOn(d.Lines[l-1]) {
					res, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: d, Lnum: l})
					if err != nil || res == nil {
						continue
					}
					if list := projectsFor(all, res.Doc.Rel, res.Lnum, res.Doc); len(list) > 0 && !seen[list[0]] {
						seen[list[0]] = true
						e.projects = append(e.projects, list[0])
					}
					break
				}
			}
			break
		}
		weeks = append(weeks, e)
	})
	sort.SliceStable(weeks, func(i, j int) bool { return weeks[i].week > weeks[j].week })
	for _, e := range weeks {
		if e.week <= want && len(e.projects) > 0 {
			return e.week, e.projects, e.week != want
		}
	}
	return "", nil, false
}

// =============================================================================
// Pages
// =============================================================================

// projectRow is a project in a list.
type projectRow struct {
	P       *webProject
	Rollup  rollup
	URL     string
	Focus   bool
	KRs     []string
	Next    *webTask
	Context string // its parents
}

func (s *Server) projectURL(p *webProject) string {
	return s.url("/project") + "?rel=" + url.QueryEscape(p.Rel) + "&lnum=" + strconv.Itoa(p.Lnum)
}

func (s *Server) row(p *webProject, focused map[*webProject]bool, krs []webKR) projectRow {
	r := projectRow{P: p, Rollup: p.rollup(), URL: s.projectURL(p)}
	for _, x := range p.lineage() {
		if focused[x] {
			r.Focus = true
		}
	}
	for _, kr := range krs {
		for _, kp := range kr.Projects {
			for _, x := range p.lineage() {
				if kp == x {
					r.KRs = append(r.KRs, kr.ID)
				}
			}
		}
	}
	p.walk(func(x *webProject) {
		for _, t := range x.Tasks {
			if r.Next == nil && !t.Done {
				r.Next = t
			}
		}
	})
	// the headings above it, projects or organizational ones
	var parents []string
	if len(p.Path) > 1 {
		parents = append(parents, p.Path[:len(p.Path)-1]...)
	}
	if len(p.Path) == 1 && p.Parent != nil && p.Parent.Root && !s.isProjectsNote(p.doc) {
		parents = append([]string{p.Parent.Name}, parents...)
	}
	r.Context = strings.Join(parents, " › ")
	return r
}

func (s *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	all := s.allProjects()
	krs := s.keyResults(all, now)
	week, focus, earlier := s.focus(all, now)
	focused := map[*webProject]bool{}
	for _, p := range focus {
		focused[p] = true
	}
	var focusRows, active, quiet []projectRow
	done := 0
	for _, p := range focus {
		focusRows = append(focusRows, s.row(p, focused, krs))
	}
	for _, p := range all {
		if p.Root && len(p.Tasks) == 0 {
			continue
		}
		if p.isDone() {
			done++
			continue
		}
		row := s.row(p, focused, krs)
		if focused[p] {
			continue
		}
		own := 0
		for _, t := range p.Tasks {
			if !t.Done {
				own++
			}
		}
		switch {
		case own > 0:
			active = append(active, row)
		case row.Rollup.Open == 0 && row.Rollup.Total > 0:
			done++
		case len(p.Children) == 0:
			quiet = append(quiet, row) // no next action
		}
	}
	s.render(w, r, "projects", http.StatusOK, map[string]any{
		"Title":   "Projects",
		"Week":    week,
		"Earlier": earlier,
		"Focus":   focusRows,
		"Active":  active,
		"Quiet":   quiet,
		"Done":    done,
	})
}

// calItem is a calendar line about the project; calDay a day of them.
type calItem struct {
	Time  string
	Text  string
	Task  bool
	Done  bool
	Moved bool
	URL   string
}

type calDay struct {
	Date  string
	Items []calItem
}

type linkedItem struct {
	Title string
	URL   string
	Line  string
}

func (s *Server) handleProject(w http.ResponseWriter, r *http.Request) {
	rel, ok := cleanRel(r.URL.Query().Get("rel"))
	lnum, _ := strconv.Atoi(r.URL.Query().Get("lnum"))
	now := time.Now()
	today := now.Format("2006-01-02")
	all := s.allProjects()
	var p *webProject
	for _, x := range all {
		if ok && x.Rel == rel && x.Lnum == lnum {
			p = x
		}
	}
	if p == nil {
		s.render(w, r, "error", http.StatusNotFound, map[string]any{"Title": "No such project", "Message": "No project starts at " + rel + ":" + strconv.Itoa(lnum) + "."})
		return
	}
	krs := s.keyResults(all, now)
	week, focus, _ := s.focus(all, now)
	focused := map[*webProject]bool{}
	for _, f := range focus {
		focused[f] = true
	}
	row := s.row(p, focused, krs)

	// its key results (on it or a parent)
	var mine []webKR
	for _, kr := range krs {
		for _, kp := range kr.Projects {
			hit := false
			for _, x := range p.lineage() {
				if kp == x {
					hit = true
				}
			}
			if hit {
				mine = append(mine, kr)
				break
			}
		}
	}

	// tasks: open ones (put off most, then in order), done ones
	var open, closed []*webTask
	for _, t := range p.Tasks {
		if t.Done {
			closed = append(closed, t)
		} else {
			open = append(open, t)
		}
	}
	sort.SliceStable(closed, func(i, j int) bool { return closed[i].DoneDate > closed[j].DoneDate })
	var children []projectRow
	for _, c := range p.Children {
		row := s.row(c, focused, krs)
		row.Context = "" // under this project already
		children = append(children, row)
	}

	// time on it
	spent, ids := 0, map[string]bool{}
	p.walk(func(x *webProject) {
		for _, t := range x.Tasks {
			spent += t.Spent
			if t.ID != "" {
				ids[t.ID] = true
			}
		}
	})
	week7 := s.spentSince(p, ids, now.AddDate(0, 0, -6).Format("2006-01-02"))

	// the log: the lines under its "Log:" label
	var logLines []template.HTML
	if node := projectLog(p); node != nil {
		rd := &noteRenderer{s: s, doc: p.doc}
		for l := node.Start + 1; l <= node.End && l <= p.OwnEnd; l++ {
			line := p.doc.Lines[l-1]
			if strings.TrimSpace(line) == "" {
				continue
			}
			col := len(line) - len(strings.TrimLeft(line, " \t"))
			if it := syntax.ItemOf(line); it != nil {
				col = it.ContentCol
			}
			logLines = append(logLines, template.HTML(strings.TrimSpace(rd.entryHTML(line, l, col))))
		}
	}

	// the calendar: lines linking into it, and copies of its tasks
	hist := s.calendarHistory()
	var days []calDay
	dayCount := 0
	if cal := s.calendarDoc(); cal != nil {
		lines := map[int]bool{}
		for _, bl := range s.current().backlinks[p.Rel] {
			if bl.From == cal.Rel && bl.ToLnum >= p.Lnum && bl.ToLnum <= p.End {
				lines[bl.Lnum] = true
			}
		}
		taskText := map[string]string{}
		p.walk(func(x *webProject) {
			for _, t := range x.Tasks {
				if t.ID != "" {
					it := syntax.ItemOf(t.Line)
					taskText[t.ID] = compactText(t.Line, it.ContentCol)
				}
			}
		})
		for id := range ids {
			if h := hist.byID[id]; h != nil {
				for _, d := range h.days {
					lines[d.lnum] = true
				}
			}
		}
		byDate := map[string]*calDay{}
		order := make([]int, 0, len(lines))
		for l := range lines {
			order = append(order, l)
		}
		sort.Ints(order)
		for _, l := range order {
			if l < 1 || l > len(cal.Lines) || hist.dateOf[l-1] == "" {
				continue
			}
			line := cal.Lines[l-1]
			it := syntax.ItemOf(line)
			item := calItem{URL: s.noteURL(cal.Rel, l)}
			col := 0
			if it != nil {
				col = it.ContentCol
				item.Task = it.Mark != ""
				item.Done, item.Moved = isDone(line), it.Mark == edit.Moved
				if it.Time != nil {
					item.Time = it.Time.At
					if item.Time == "" {
						item.Time = it.Time.From + "–" + it.Time.To
					}
				}
			}
			if t, ok := taskText[edit.ID(line)]; ok {
				item.Text = t
			} else {
				item.Text = compactText(line, col)
			}
			if !item.Task {
				if ref := s.referenceOf(cal, l); ref != nil {
					item.Task, item.Done = true, ref.Done
				}
			}
			date := hist.dateOf[l-1]
			d := byDate[date]
			if d == nil {
				d = &calDay{Date: date}
				byDate[date] = d
			}
			d.Items = append(d.Items, item)
		}
		for _, d := range byDate {
			days = append(days, *d)
		}
		sort.Slice(days, func(i, j int) bool { return days[i].Date > days[j].Date })
		dayCount = len(days)
		if len(days) > 14 {
			days = days[:14]
		}
	}

	// notes and files it links, notes that link it
	skip := map[string]bool{}
	if cal := s.calendarDoc(); cal != nil {
		skip[cal.Rel] = true
	}
	if rv := s.reviewsDoc(); rv != nil {
		skip[rv.Rel] = true
	}
	for _, d := range s.okrDocs() {
		skip[d.Rel] = true
	}
	snap := s.current()
	var linksTo, filesTo, linkedFrom []linkedItem
	seenTo := map[string]bool{}
	for _, o := range snap.forward[p.Rel] {
		if o.Lnum >= p.Lnum && o.Lnum <= p.End && o.To != p.Rel && !seenTo[o.To] {
			seenTo[o.To] = true
			linksTo = append(linksTo, linkedItem{Title: s.noteTitle(o.To), URL: s.noteURL(o.To, 0)})
		}
	}
	for res, bls := range snap.fileBacklinks {
		for _, bl := range bls {
			if bl.From == p.Rel && bl.Lnum >= p.Lnum && bl.Lnum <= p.End {
				filesTo = append(filesTo, linkedItem{Title: res, URL: s.fileURL(res)})
				break
			}
		}
	}
	sort.Slice(filesTo, func(i, j int) bool { return filesTo[i].Title < filesTo[j].Title })
	for _, bl := range snap.backlinks[p.Rel] {
		if bl.ToLnum >= p.Lnum && bl.ToLnum <= p.End && !skip[bl.From] {
			linkedFrom = append(linkedFrom, linkedItem{Title: s.noteTitle(bl.From), URL: s.noteURL(bl.From, bl.Lnum), Line: strings.TrimSpace(syntax.StripAttributes(bl.Line))})
		}
	}

	// breadcrumbs: its parents
	var crumbs []projectRow
	for x := p.Parent; x != nil; x = x.Parent {
		if x.Root && s.isProjectsNote(x.doc) {
			break
		}
		crumbs = append([]projectRow{{P: x, URL: s.projectURL(x)}}, crumbs...)
	}
	var areas []linkedItem
	for _, x := range p.lineage() {
		for _, a := range x.Areas {
			for _, def := range areaDefinitions(a) {
				title := a
				if res, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{}); err == nil && res != nil {
					if n := res.Doc.NodeAt(res.Lnum); n != nil && !n.IsRoot() {
						title = n.Text
					}
				}
				areas = append(areas, linkedItem{Title: title, URL: s.linkURL(def, x.Rel)})
			}
		}
	}

	s.render(w, r, "project", http.StatusOK, map[string]any{
		"Title":      p.Name,
		"NavTab":     "projects",
		"P":          p,
		"Row":        row,
		"Crumbs":     crumbs,
		"Areas":      areas,
		"Week":       week,
		"KRs":        mine,
		"Open":       open,
		"Closed":     closed,
		"Children":   children,
		"Log":        logLines,
		"HasLog":     projectLog(p) != nil,
		"Days":       days,
		"DayCount":   dayCount,
		"Spent":      formatMinutes(spent),
		"SpentAny":   spent > 0,
		"Week7":      formatMinutes(week7),
		"Week7Any":   week7 > 0,
		"LinksTo":    linksTo,
		"FilesTo":    filesTo,
		"LinkedFrom": linkedFrom,
		"SourceURL":  s.noteURL(p.Rel, p.Lnum),
		"Heading":    p.doc.Lines[p.Lnum-1],
		"Writable":   s.cfg.Writable,
		"Today":      today,
	})
}

// formatHours: 0.5 -> "30m", 3 -> "3h", 2.25 -> "2h15m".
func formatHours(h float64) string {
	m := int(math.Round(h * 60))
	if m <= 0 {
		return "0h"
	}
	return formatMinutes(m)
}

// withoutLinks: a line's text from col on, attributes and links removed
// ("Bake every weekend [P/#2.2]" -> "Bake every weekend").
func withoutLinks(line string, col int) string {
	var b strings.Builder
	pos := col
	for _, sp := range links.LinksOn(line) {
		if sp.S < col {
			continue
		}
		b.WriteString(line[pos:sp.S])
		pos = sp.E
	}
	b.WriteString(line[pos:])
	return strings.Join(strings.Fields(syntax.StripAttributes(b.String())), " ")
}

// compactText: a line's text from col on, attributes removed and every link
// shown as its last component's text ("[P/#2 Learning/#2.2 Bake]" -> "2.2 Bake").
func compactText(line string, col int) string {
	if col < 0 || col > len(line) {
		col = 0
	}
	var b strings.Builder
	pos := col
	for _, sp := range links.LinksOn(line) {
		if sp.S < col {
			continue
		}
		b.WriteString(line[pos:sp.S])
		def := links.Parse("[" + sp.Definition + "]")
		text := sp.Definition
		if n := len(def.Components); n > 0 {
			text = def.Components[n-1].Text
		}
		b.WriteString(text)
		pos = sp.E
	}
	b.WriteString(line[pos:])
	return strings.Join(strings.Fields(syntax.StripAttributes(b.String())), " ")
}

// spentSince: minutes tracked on the project's tasks from `from` on
// (.z/time_spent.json).
func (s *Server) spentSince(p *webProject, ids map[string]bool, from string) int {
	raw, err := os.ReadFile(s.timeSpentPath())
	if err != nil {
		return 0
	}
	var ts timeSpent
	if json.Unmarshal(raw, &ts) != nil {
		return 0
	}
	total := 0
	for day, list := range ts.Days {
		if day < from {
			continue
		}
		for _, e := range list {
			if (e.ID != "" && ids[e.ID]) || (e.Rel == p.Rel && e.Lnum >= p.Lnum && e.Lnum <= p.End) {
				total += e.Minutes
			}
		}
	}
	return total
}

// projectLog: the "Log:" label in the project's own part, or nil.
func projectLog(p *webProject) *notes.Node {
	var found *notes.Node
	p.doc.Tree.Walk(func(n *notes.Node) {
		if found == nil && n.Type == syntax.KindLabel && strings.EqualFold(n.Text, "Log") && n.Start > p.Lnum && n.Start <= p.OwnEnd {
			found = n
		}
	})
	return found
}

// apiProjectLog: POST /api/project/log {rel, lnum, expect, text}: a dated
// line at the top of the project's "Log:" label (the label made, after its
// own content, when it has none).
func (s *Server) apiProjectLog(w http.ResponseWriter, r *http.Request) {
	if !s.writableOK(w, r) {
		return
	}
	var req struct {
		Rel    string `json:"rel"`
		Lnum   int    `json:"lnum"`
		Expect string `json:"expect"`
		Text   string `json:"text"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return
	}
	text := strings.Join(strings.Fields(req.Text), " ")
	if text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "nothing to add"})
		return
	}
	rel, ok := cleanRel(req.Rel)
	if !ok || !s.isNote(rel) || s.ix.Doc(rel) == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such note: " + req.Rel})
		return
	}
	s.editMu.Lock()
	f, err := readNoteFile(s.ix.Path(rel))
	if err != nil {
		s.editMu.Unlock()
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if req.Lnum < 1 || req.Lnum > len(f.lines) || f.lines[req.Lnum-1] != req.Expect {
		s.editMu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]any{"error": errChanged.Error()})
		return
	}
	doc := notes.FromLines(rel, f.lines)
	var p *webProject
	s.buildProjects(doc, s.calibration(), &calendarHistory{byID: map[string]*idHistory{}}, "").walk(func(x *webProject) {
		if x.Lnum == req.Lnum {
			p = x
		}
	})
	if p == nil {
		s.editMu.Unlock()
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no project at that line"})
		return
	}
	entry := "- " + time.Now().Format("2006-01-02") + ": " + text
	at, insert := 0, []string(nil)
	if node := projectLog(p); node != nil {
		lead := f.lines[node.Start-1]
		at, insert = node.Start, []string{lead[:len(lead)-len(strings.TrimLeft(lead, " \t"))] + entry}
	} else {
		at = p.Lnum // after its last non-blank line
		for l := p.OwnEnd; l > p.Lnum; l-- {
			if strings.TrimSpace(f.lines[l-1]) != "" {
				at = l
				break
			}
		}
		insert = []string{"", "Log:", entry}
		if at < len(f.lines) && strings.TrimSpace(f.lines[at]) != "" {
			insert = append(insert, "")
		}
	}
	f.lines = append(f.lines[:at], append(insert, f.lines[at:]...)...)
	err = f.write()
	s.editMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	s.afterWrite()
	s.log.Printf("project log %s:%d", rel, req.Lnum)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "line": entry})
}

// groupTitle: a group's text, for its tasks' "in <group>" note.
func groupTitle(line string) string {
	if it := syntax.ItemOf(line); it != nil {
		return strings.TrimSpace(syntax.StripAttributes(line[it.ContentCol:]))
	}
	return strings.TrimSpace(syntax.StripAttributes(line))
}
