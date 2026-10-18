package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"path"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
	"github.com/t-wilkinson/zortex.nvim/app/tracker"
)

// Task copies (lua/zortex/services/mirrors.lua has the rules): a project
// task put on the calendar keeps its @id, and every line in the calendar
// and the project notes with that @id is the same task.
//
//   - a project task is done when it or a calendar copy is checked; its
//     page shows it done (mirrored)
//   - toggling any of them here updates the others (syncMirrors), as
//     Neovim does
//   - a calendar line without a checkbox whose link points at a task stands
//     for it: the calendar shows the task's state and toggling it toggles
//     the task (referenceOf)
//   - a calendar task without @id whose link points at a task takes the
//     task's @id when toggled, becoming its copy (adoptID)
//   - copies carried to a later day are marked [>] (edit.Moved) and left
//     alone
//
//	POST /api/calendar/carry   {date?}: copy the open tasks of the 14 days
//	                           before to the date (default today), marking
//	                           the old lines [>] (edit.Carry)

const carryDays = 14

// isProjectDoc: the Projects note (projects.zortex, or @@P) and notes tagged @P.
func (s *Server) isProjectDoc(doc *notes.Document) bool {
	if doc == nil {
		return false
	}
	if strings.EqualFold(doc.Rel, "projects"+s.cfg.Ext) {
		return true
	}
	h := doc.Header()
	return syntax.ListHas(h.Tags, "P") || syntax.ListHas(h.Names, "P")
}

// mirrorRels: the notes whose tasks can share an @id.
func (s *Server) mirrorRels() []string {
	var out []string
	cal := s.calendarDoc()
	for _, rel := range s.ix.All() {
		if s.ix.IsArchived(rel) {
			continue
		}
		if d := s.ix.Doc(rel); d != nil && (d == cal || s.isProjectDoc(d)) {
			out = append(out, rel)
		}
	}
	return out
}

// copyState is what the calendar copies of one @id say.
type copyState struct {
	Done bool
	Date string // the earliest @done of a checked copy
}

type copyCache struct {
	mu  sync.Mutex
	doc *notes.Document
	ids map[string]copyState
}

// calendarCopies: @id -> its calendar copies' state.
func (s *Server) calendarCopies() map[string]copyState {
	doc := s.calendarDoc()
	c := &s.copies
	c.mu.Lock()
	defer c.mu.Unlock()
	if doc == c.doc && c.ids != nil {
		return c.ids
	}
	ids := map[string]copyState{}
	if doc != nil {
		for i, line := range doc.Lines {
			if !strings.Contains(line, "@id(") || doc.InCode(i+1) {
				continue
			}
			id := edit.ID(line)
			it := syntax.ItemOf(line)
			if id == "" || it == nil || it.Mark == "" {
				continue
			}
			st := ids[id]
			if isDone(line) {
				st.Done = true
				if d, ok := edit.Attribute(line, "done"); ok && (st.Date == "" || d < st.Date) {
					st.Date = d
				}
			}
			ids[id] = st
		}
	}
	c.doc, c.ids = doc, ids
	return ids
}

// doneOnCalendar: an open task line of a project note whose calendar copy is
// checked.
func (s *Server) doneOnCalendar(doc *notes.Document, line string) bool {
	id := edit.ID(line)
	if id == "" || !s.isProjectDoc(doc) {
		return false
	}
	return s.calendarCopies()[id].Done
}

// ---------------------------------------------------------------------------
// References
// ---------------------------------------------------------------------------

// taskRef is the task a calendar line stands for.
type taskRef struct {
	Rel  string
	Lnum int
	Line string
	Done bool
}

// referenceOf: line lnum of doc has no checkbox and its first link points at
// a task: that task. Otherwise nil.
func (s *Server) referenceOf(doc *notes.Document, lnum int) *taskRef {
	if doc == nil || lnum < 1 || lnum > len(doc.Lines) {
		return nil
	}
	if it := syntax.ItemOf(doc.Lines[lnum-1]); it != nil && it.Mark != "" {
		return nil
	}
	return s.linkedTask(doc, lnum)
}

// linkedTask: the task line lnum's first link points at, whether or not the
// line has a checkbox. Otherwise nil.
func (s *Server) linkedTask(doc *notes.Document, lnum int) *taskRef {
	if doc == nil || lnum < 1 || lnum > len(doc.Lines) {
		return nil
	}
	line := doc.Lines[lnum-1]
	if !strings.Contains(line, "[") {
		return nil
	}
	spans := links.LinksOn(line)
	if len(spans) == 0 {
		return nil
	}
	def, err := links.Absolute(doc.Lines, lnum, spans[0].Definition)
	if err != nil || s.fileLike(def) {
		return nil
	}
	r, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{From: doc, Lnum: lnum})
	if err != nil || r == nil || r.Whole {
		return nil
	}
	target := r.Doc.Lines[r.Lnum-1]
	it := syntax.ItemOf(target)
	if it == nil || it.Mark == "" {
		return nil
	}
	return &taskRef{
		Rel: r.Doc.Rel, Lnum: r.Lnum, Line: target,
		Done: isDone(target) || s.doneOnCalendar(r.Doc, target),
	}
}

// adoptID: a calendar task with no @id whose link points at a task becomes a
// copy of it: the line takes the task's @id (the task gets one first if it
// has none), so toggling either toggles both. Returns the calendar line with
// the @id, or "" when there is nothing to adopt. Call with editMu held.
func (s *Server) adoptID(cal *notes.Document, lnum int) (string, error) {
	line := cal.Lines[lnum-1]
	it := syntax.ItemOf(line)
	if it == nil || it.Mark == "" || edit.ID(line) != "" {
		return "", nil
	}
	ref := s.linkedTask(cal, lnum)
	if ref == nil || ref.Rel == cal.Rel {
		return "", nil
	}
	id := edit.ID(ref.Line)
	if id == "" {
		f, err := readNoteFile(s.ix.Path(ref.Rel))
		if err != nil {
			return "", err
		}
		if ref.Lnum > len(f.lines) || f.lines[ref.Lnum-1] != ref.Line {
			return "", nil // changed since the index read it
		}
		id = s.newID()
		f.lines[ref.Lnum-1] = edit.AddAttribute(ref.Line, "id", id)
		if err := f.write(); err != nil {
			return "", err
		}
	}
	return edit.AddAttribute(line, "id", id), nil
}

// ---------------------------------------------------------------------------
// Keeping copies in step
// ---------------------------------------------------------------------------

// syncMirrors gives every other line with line's @id (in the calendar and
// the project notes) line's state: checked with the same @done, or open.
// Moved copies ([>]) are left alone. Call with editMu held. Returns the
// notes it changed and the lines.
func (s *Server) syncMirrors(rel string, lnum int, line string) ([]string, []lineChange, error) {
	id := edit.ID(line)
	it := syntax.ItemOf(line)
	if id == "" || it == nil || it.Mark == "" || it.Mark == edit.Moved {
		return nil, nil, nil
	}
	done := isDone(line)
	op, date := edit.Open, today()
	if done {
		op = edit.Done
		if d, ok := edit.Attribute(line, "done"); ok {
			date = d
		}
	}
	needle := "@id(" + id + ")"
	var changed []string
	var lines []lineChange
	var errs []error
	for _, r := range s.mirrorRels() {
		f, err := readNoteFile(s.ix.Path(r))
		if err != nil {
			errs = append(errs, err)
			continue
		}
		n := 0
		var mine []lineChange
		for i, l := range f.lines {
			if (r == rel && i+1 == lnum) || !strings.Contains(l, needle) {
				continue
			}
			other := syntax.ItemOf(l)
			if other == nil || other.Mark == "" || other.Mark == edit.Moved || isDone(l) == done {
				continue
			}
			next, err := edit.Line(l, op, date, s.newID)
			if err != nil {
				continue
			}
			f.lines[i] = next
			mine = append(mine, lineChange{Rel: r, Lnum: i + 1, Line: next})
			n++
		}
		if n > 0 {
			if err := f.write(); err != nil {
				errs = append(errs, err)
				continue
			}
			changed = append(changed, r)
			lines = append(lines, mine...)
		}
	}
	return changed, lines, errors.Join(errs...)
}

// ---------------------------------------------------------------------------
// Problems
// ---------------------------------------------------------------------------

// mirrorIssues: ids that don't line up, listed on /broken: two project tasks
// with the same @id, and calendar copies whose link points at another task
// than their @id.
func (s *Server) mirrorIssues() []Broken {
	type at struct {
		rel  string
		lnum int
	}
	origin := map[string]at{}
	var out []Broken
	for _, rel := range s.mirrorRels() {
		doc := s.ix.Doc(rel)
		if doc == nil || !s.isProjectDoc(doc) {
			continue
		}
		for i, l := range doc.Lines {
			id := edit.ID(l)
			it := syntax.ItemOf(l)
			if id == "" || it == nil || it.Mark == "" || doc.InCode(i+1) {
				continue
			}
			if o, ok := origin[id]; ok {
				out = append(out, Broken{From: rel, FromNote: true, Lnum: i + 1, Def: "@id(" + id + ")",
					Err: fmt.Sprintf("also on %s:%d", o.rel, o.lnum)})
				continue
			}
			origin[id] = at{rel, i + 1}
		}
	}
	cal := s.calendarDoc()
	if cal != nil {
		for i, l := range cal.Lines {
			id := edit.ID(l)
			o, ok := origin[id]
			if id == "" || !ok || cal.InCode(i+1) {
				continue
			}
			it := syntax.ItemOf(l)
			if it == nil || it.Mark == "" {
				continue
			}
			spans := links.LinksOn(l)
			if len(spans) == 0 {
				continue
			}
			def, err := links.Absolute(cal.Lines, i+1, spans[0].Definition)
			if err != nil || s.fileLike(def) {
				continue
			}
			r, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{From: cal, Lnum: i + 1})
			if err != nil || r == nil || r.Whole {
				continue
			}
			if ti := syntax.ItemOf(r.Doc.Lines[r.Lnum-1]); ti == nil || ti.Mark == "" {
				continue
			}
			if r.Doc.Rel != o.rel || r.Lnum != o.lnum {
				out = append(out, Broken{From: cal.Rel, FromNote: true, Lnum: i + 1, Def: "@id(" + id + ")",
					Err: fmt.Sprintf("is %s:%d but the link points at %s:%d", o.rel, o.lnum, r.Doc.Rel, r.Lnum)})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].From != out[j].From {
			return out[i].From < out[j].From
		}
		return out[i].Lnum < out[j].Lnum
	})
	return out
}

// ---------------------------------------------------------------------------
// Time tracking: the task to work on in a running block
// ---------------------------------------------------------------------------

// blockTask: the first open task nested under calendar line lnum (a copy,
// or the task a reference line stands for), or nil. Under
// "09:00 [P/#1.4 - zortex]" the time goes to the task you're on; ticking
// it moves on to the next.
func (s *Server) blockTask(doc *notes.Document, lnum int) *tracker.Target {
	if doc == nil || lnum < 1 || lnum > len(doc.Lines) {
		return nil
	}
	base := edit.Indent(doc.Lines[lnum-1])
	for l := lnum + 1; l <= len(doc.Lines); l++ {
		line := doc.Lines[l-1]
		if strings.TrimSpace(line) == "" {
			continue
		}
		if _, day := edit.DateHeading(line); edit.Indent(line) <= base || day {
			break
		}
		it := syntax.ItemOf(line)
		if it == nil {
			continue
		}
		if it.Mark == " " {
			return targetFor(doc, l)
		}
		if it.Mark == "" {
			if ref := s.referenceOf(doc, l); ref != nil && !ref.Done {
				return targetFor(s.ix.Doc(ref.Rel), ref.Lnum)
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Carrying open tasks forward
// ---------------------------------------------------------------------------

// carryPlan: what carrying to `date` would change in the calendar's lines.
func (s *Server) carryPlan(lines []string, date string, newID func() string) edit.CarryPlan {
	d, err := time.Parse("2006-01-02", date)
	if err != nil {
		return edit.CarryPlan{}
	}
	from := d.AddDate(0, 0, -carryDays).Format("2006-01-02")
	return edit.Carry(lines, date, from, newID)
}

// carryCount: how many open tasks carrying to `date` would copy (for the
// home page's button).
func (s *Server) carryCount(date string) int {
	doc := s.calendarDoc()
	if doc == nil {
		return 0
	}
	return s.carryPlan(doc.Lines, date, func() string { return "x" }).Added()
}

// apiCarry: POST /api/calendar/carry {date?}
func (s *Server) apiCarry(w http.ResponseWriter, r *http.Request) {
	if !s.writableOK(w, r) {
		return
	}
	var req struct {
		Date string `json:"date"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&req)
	if req.Date == "" {
		req.Date = today()
	}
	if !isDate(req.Date) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "date: YYYY-MM-DD"})
		return
	}
	doc := s.calendarDoc()
	if doc == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no calendar note"})
		return
	}
	s.editMu.Lock()
	f, err := readNoteFile(s.ix.Path(doc.Rel))
	if err != nil {
		s.editMu.Unlock()
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	plan := s.carryPlan(f.lines, req.Date, s.newID)
	f.lines = plan.Apply(f.lines)
	added := plan.Added()
	if len(plan.Edits) > 0 {
		err = f.write()
	}
	s.editMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if len(plan.Edits) > 0 {
		s.afterWrite()
		s.log.Printf("carry: %d task(s) to %s, %d copied", len(plan.Edits), req.Date, added)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "moved": len(plan.Edits), "added": added, "date": req.Date, "rel": path.Clean(doc.Rel)})
}
