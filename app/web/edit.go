package web

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Editing (zortex serve -writable): small, line-level changes to notes from
// the web, for when you're away from Neovim:
//
//	POST /api/n/{rel} {lnum, expect, op, text?, kind?}
//	  op open | done | toggle | text    task state (app/edit, as Neovim does it)
//	     set                            replace the line's text after its marker
//	     delete                         remove the line
//	     insert                         add a line after lnum (kind task | note | text)
//	     move                           move the line and its indented sub-lines
//	                                    before line `to` (len+1: the end), lined
//	                                    up with the lines around it; `expectTo`
//	                                    is the text of line `to`
//	POST /api/inbox  {text, kind, id?}  append a task or a note to inbox.zortex;
//	                                    id (optional, from the offline queue)
//	                                    makes a resend a no-op
//
// Task ops keep copies in step (mirrors.go): the other lines with the
// task's @id in the calendar and the project notes get the same state, and
// on a calendar line without a checkbox that links a task they act on that
// task.
//
// Every edit names the line it expects (`expect`); when the file changed
// since the page was loaded (Neovim, Syncthing) nothing is written and the
// reply is 409 with the current note. Files are replaced atomically through
// a temporary file Syncthing ignores. XP isn't computed here: Neovim counts
// completed tasks from their @done dates when it next looks; until then the
// home page shows how many web completions are waiting.

const inboxRel = "inbox.zortex"

var errChanged = errors.New("the note changed since this page was loaded")

type editRequest struct {
	Rel    string `json:"rel"`
	Lnum   int    `json:"lnum"`
	Expect string `json:"expect"`
	Op     string `json:"op"`
	Text   string `json:"text"`
	Kind   string `json:"kind"`
	// move
	To       int    `json:"to"`
	ExpectTo string `json:"expectTo"`
}

// noteFile is a note's lines plus how to write them back unchanged.
type noteFile struct {
	path  string
	lines []string
	crlf  bool
	bom   bool
	final bool // ends with a newline
	mode  os.FileMode
}

func readNoteFile(path string) (*noteFile, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	s := string(raw)
	return &noteFile{
		path:  path,
		lines: syntax.SplitLines(s),
		crlf:  strings.Contains(s, "\r\n"),
		bom:   strings.HasPrefix(s, "\xef\xbb\xbf"),
		final: strings.HasSuffix(s, "\n") || s == "",
		mode:  st.Mode().Perm(),
	}, nil
}

func (f *noteFile) bytes() []byte {
	nl := "\n"
	if f.crlf {
		nl = "\r\n"
	}
	var b bytes.Buffer
	if f.bom {
		b.WriteString("\xef\xbb\xbf")
	}
	b.WriteString(strings.Join(f.lines, nl))
	if f.final && len(f.lines) > 0 {
		b.WriteString(nl)
	}
	return b.Bytes()
}

// write replaces the file atomically. The temporary name follows Syncthing's
// own pattern (.syncthing.*.tmp), which Syncthing never picks up.
func (f *noteFile) write() error {
	dir, name := filepath.Split(f.path)
	tmp, err := os.CreateTemp(dir, ".syncthing."+name+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(f.bytes()); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), f.mode); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), f.path)
}

// editable: lines below the header, outside code and math blocks.
func editableLine(f *noteFile, lnum int) error {
	if lnum < 1 || lnum > len(f.lines) {
		return fmt.Errorf("no line %d", lnum)
	}
	ast := syntax.Parse(f.lines, false)
	if lnum <= ast.Header.LastLnum {
		return errors.New("the header can't be edited here")
	}
	switch ast.Lines[lnum-1].Kind {
	case syntax.KindFence, syntax.KindMathFence, syntax.KindCode, syntax.KindMath, syntax.KindTable:
		return errors.New("code, math and tables can't be edited here")
	}
	return nil
}

func today() string { return time.Now().Format("2006-01-02") }

func (s *Server) newID() string {
	for i := 0; i < 50; i++ {
		id := edit.NewID()
		if !s.idInUse(id) {
			return id
		}
	}
	return edit.NewID()
}

func (s *Server) idInUse(id string) bool {
	needle := "@id(" + id + ")"
	for _, rel := range s.ix.All() {
		if d := s.ix.Doc(rel); d != nil {
			for _, l := range d.Lines {
				if strings.Contains(l, needle) {
					return true
				}
			}
		}
	}
	return false
}

// newLine builds an inserted line from its kind and text.
func (s *Server) newLine(indent, kind, text string) (string, error) {
	text = strings.TrimSpace(strings.ReplaceAll(text, "\n", " "))
	if text == "" {
		return "", errors.New("empty text")
	}
	switch kind {
	case "task":
		return edit.Line(indent+"- "+text, edit.Open, today(), s.newID)
	case "note", "":
		return indent + "- " + text, nil
	case "text":
		return indent + text, nil
	}
	return "", fmt.Errorf("unknown kind %q", kind)
}

// indentFor: an inserted line lines up with the line above it, except after
// headings (top level).
func indentFor(line string) string {
	d := syntax.Classify(line)
	switch d.Kind {
	case syntax.KindHeading, syntax.KindBoldHeading, syntax.KindArticle:
		return ""
	}
	n := 0
	for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
		n++
	}
	return line[:n]
}

func isDone(line string) bool {
	it := syntax.ItemOf(line)
	return it != nil && (it.Mark == "x" || it.Mark == "X")
}

// applyEdit changes f in memory; returns the line number to show afterwards.
func (s *Server) applyEdit(f *noteFile, req editRequest) (int, error) {
	if req.Op == "insert" {
		if req.Lnum < 0 || req.Lnum > len(f.lines) {
			return 0, fmt.Errorf("no line %d", req.Lnum)
		}
		ast := syntax.Parse(f.lines, false)
		if req.Lnum < ast.Header.LastLnum {
			return 0, errors.New("the header can't be edited here")
		}
		indent := ""
		if req.Lnum > 0 {
			if f.lines[req.Lnum-1] != req.Expect {
				return 0, errChanged
			}
			if req.Lnum > ast.Header.LastLnum {
				if err := editableLine(f, req.Lnum); err != nil {
					return 0, err
				}
				indent = indentFor(f.lines[req.Lnum-1])
			}
		}
		line, err := s.newLine(indent, req.Kind, req.Text)
		if err != nil {
			return 0, err
		}
		f.lines = append(f.lines[:req.Lnum], append([]string{line}, f.lines[req.Lnum:]...)...)
		return req.Lnum + 1, nil
	}

	if req.Lnum < 1 || req.Lnum > len(f.lines) || f.lines[req.Lnum-1] != req.Expect {
		return 0, errChanged
	}
	if req.Op == "move" {
		if req.To < 1 || req.To > len(f.lines)+1 || (req.To <= len(f.lines) && f.lines[req.To-1] != req.ExpectTo) {
			return 0, errChanged
		}
		lines, lnum, err := moveBlock(f.lines, req.Lnum, req.To)
		if err != nil {
			return 0, err
		}
		f.lines = lines
		return lnum, nil
	}
	if err := editableLine(f, req.Lnum); err != nil {
		return 0, err
	}
	i := req.Lnum - 1
	switch req.Op {
	case edit.Open, edit.Done, edit.Toggle, edit.Text:
		switch syntax.Classify(f.lines[i]).Kind {
		case syntax.KindItem, syntax.KindText, syntax.KindLabel:
		default:
			return 0, errors.New("only list items and text lines can be tasks")
		}
		was := f.lines[i]
		line, err := edit.Line(was, req.Op, today(), s.newID)
		if err != nil {
			return 0, err
		}
		f.lines[i] = line
		// the only task of a calendar block, unsized: the block's length
		if edit.Ticked(line) && !edit.Ticked(was) {
			if size := edit.CalendarSize(f.lines, req.Lnum, s.calibration().TaskHours); size != "" {
				f.lines[i] = line + " @" + size
			}
		}
	case "set":
		line := f.lines[i]
		col := 0
		if d := syntax.Classify(line); d.ContentCol != nil {
			col = *d.ContentCol
		}
		text := strings.ReplaceAll(req.Text, "\n", " ")
		if strings.TrimSpace(text) == "" {
			return 0, errors.New("empty text: delete the line instead")
		}
		// @id and @done are bookkeeping the editor doesn't show: keep them
		next := line[:col] + text
		for _, key := range []string{"id", "done"} {
			if v, ok := edit.Attribute(line, key); ok {
				next = edit.AddAttribute(next, key, v)
			}
		}
		f.lines[i] = next
	case "delete":
		f.lines = append(f.lines[:i], f.lines[i+1:]...)
		if i >= len(f.lines) {
			return len(f.lines), nil
		}
	default:
		return 0, fmt.Errorf("unknown op %q", req.Op)
	}
	return req.Lnum, nil
}

// indentWidth: leading whitespace, a tab counting as four columns.
func indentWidth(line string) (int, string) {
	w, n := 0, 0
	for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
		if line[n] == '\t' {
			w += 4
		} else {
			w++
		}
		n++
	}
	return w, line[:n]
}

func blank(line string) bool { return strings.TrimSpace(line) == "" }

// blockEnd: the last line (1-based) of the block that starts at lnum: the
// line plus the lines below it indented deeper (blank lines between them
// included, trailing blank lines not).
func blockEnd(lines []string, lnum int) int {
	w, _ := indentWidth(lines[lnum-1])
	end := lnum
	for i := lnum; i < len(lines); i++ { // i: 0-based index of line i+1
		l := lines[i]
		if blank(l) {
			continue
		}
		if lw, _ := indentWidth(l); lw <= w {
			break
		}
		end = i + 1
	}
	return end
}

// moveBlock moves line `from` and its sub-lines (blockEnd) to stand before
// line `to` (len+1: the end). The block is re-indented to line up with
// where it lands: like the line it now precedes when that's a list item or
// text, otherwise like the nearest line above it (top level after a
// heading). It returns the new lines and where the moved line is now.
func moveBlock(lines []string, from, to int) ([]string, int, error) {
	if from < 1 || from > len(lines) || to < 1 || to > len(lines)+1 {
		return nil, 0, errors.New("no such line")
	}
	ast := syntax.Parse(lines, false)
	movable := func(lnum int) bool {
		if lnum <= ast.Header.LastLnum {
			return false
		}
		for _, b := range ast.Blocks {
			if lnum > b.Start && lnum <= b.Finish {
				return false
			}
		}
		return true
	}
	switch ast.Lines[from-1].Kind {
	case syntax.KindItem, syntax.KindText, syntax.KindLabel, syntax.KindQuote:
	default:
		return nil, 0, errors.New("only list items and text lines can be moved")
	}
	if !movable(from) {
		return nil, 0, errors.New("that line can't be moved here")
	}
	if to <= ast.Header.LastLnum || !movable(to) && to <= len(lines) {
		return nil, 0, errors.New("lines can't be moved into the header, code or tables")
	}
	end := blockEnd(lines, from)
	for _, b := range ast.Blocks {
		if end >= b.Start && end < b.Finish {
			return nil, 0, errors.New("that line can't be moved: a code block below it isn't indented with it")
		}
	}
	if to > from && to <= end {
		return nil, 0, errors.New("a line can't be moved inside itself")
	}
	block := append([]string(nil), lines[from-1:end]...)
	rest := append(append([]string(nil), lines[:from-1]...), lines[end:]...)
	at := to - 1 // index in rest
	if to > end {
		at -= len(block)
	}

	// re-indent like the neighbours
	indent := ""
	ref := -1
	if at < len(rest) && !blank(rest[at]) {
		switch syntax.Classify(rest[at]).Kind {
		case syntax.KindItem, syntax.KindText, syntax.KindLabel, syntax.KindQuote:
			ref = at
		}
	}
	if ref < 0 {
		for i := at - 1; i >= 0; i-- {
			if !blank(rest[i]) {
				ref = i
				break
			}
		}
	}
	if ref >= 0 && ref >= ast.Header.LastLnum {
		indent = indentFor(rest[ref])
	}
	_, old := indentWidth(block[0])
	if indent != old {
		for i, l := range block {
			if strings.HasPrefix(l, old) && !blank(l) {
				block[i] = indent + l[len(old):]
			}
		}
	}

	out := make([]string, 0, len(lines))
	out = append(out, rest[:at]...)
	out = append(out, block...)
	out = append(out, rest[at:]...)
	return out, at + 1, nil
}

func (s *Server) writableOK(w http.ResponseWriter, r *http.Request) bool {
	if !s.cfg.Writable {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "read-only: start zortex serve with -writable to edit notes"})
		return false
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json)"})
		return false
	}
	return true
}

// afterWrite makes the change visible right away and rebuilds links and
// search in the background.
func (s *Server) afterWrite() {
	_, rels := s.ix.ScanChanges()
	go s.rebuild(s.scanResources())
	s.notesChanged(rels)
}

// noteState: what the page needs to redraw a note after an edit.
func (s *Server) noteState(rel string) map[string]any {
	doc := s.ix.Doc(rel)
	if doc == nil {
		return map[string]any{}
	}
	out := map[string]any{"rel": rel, "title": doc.Title(), "body": s.renderNote(doc), "mod": doc.ModTime.UnixNano()}
	if s.cfg.Writable {
		out["src"] = s.lineSources(doc.Lines)
	}
	return out
}

// apiNote: GET /api/n/{rel} -> {rel, title, body, mod, src?}: the note
// rendered (an open page redraws a note that changed, see /api/events).
func (s *Server) apiNote(w http.ResponseWriter, r *http.Request) {
	rel, _ := cleanRel(r.PathValue("rel"))
	if s.ix.Doc(rel) == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such note"})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.noteState(rel))
}

// lineSource is what the editor needs per line: the text as written and
// where its content starts (after the list marker and checkbox).
type lineSource struct {
	Text string `json:"t"`
	Col  int    `json:"c"`
	Edit bool   `json:"e"`
}

func (s *Server) lineSources(lines []string) []lineSource {
	ast := syntax.Parse(lines, false)
	out := make([]lineSource, len(lines))
	for i, l := range lines {
		d := ast.Lines[i]
		col := 0
		if d.ContentCol != nil {
			col = *d.ContentCol
		}
		ok := i+1 > ast.Header.LastLnum
		switch d.Kind {
		case syntax.KindFence, syntax.KindMathFence, syntax.KindCode, syntax.KindMath, syntax.KindTable:
			ok = false
		}
		out[i] = lineSource{Text: l, Col: col, Edit: ok}
	}
	return out
}

func (s *Server) apiEdit(w http.ResponseWriter, r *http.Request) {
	if !s.writableOK(w, r) {
		return
	}
	var req editRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return
	}
	req.Rel = r.PathValue("rel") // POST /api/n/{rel}
	rel, ok := cleanRel(req.Rel)
	if !ok || rel == "" || !s.isNote(rel) || s.ix.Doc(rel) == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such note: " + req.Rel})
		return
	}
	page := rel // the note the reply redraws
	taskOp := req.Op == edit.Open || req.Op == edit.Done || req.Op == edit.Toggle
	if cal := s.calendarDoc(); taskOp && cal != nil && cal.Rel == rel &&
		req.Lnum >= 1 && req.Lnum <= len(cal.Lines) && cal.Lines[req.Lnum-1] == req.Expect {
		// a line standing for a task ("09:00 [P/…/-Improve website]"): toggle the task
		if ref := s.referenceOf(cal, req.Lnum); ref != nil {
			if req.Op == edit.Toggle {
				req.Op = edit.Done
				if ref.Done {
					req.Op = edit.Open
				}
			}
			rel, req.Lnum, req.Expect = ref.Rel, ref.Lnum, ref.Line
		}
	}
	s.editMu.Lock()
	adopted := ""
	if cal := s.calendarDoc(); taskOp && cal != nil && cal.Rel == rel &&
		req.Lnum >= 1 && req.Lnum <= len(cal.Lines) && cal.Lines[req.Lnum-1] == req.Expect {
		// a calendar task without @id linking a task becomes its copy
		var aerr error
		if adopted, aerr = s.adoptID(cal, req.Lnum); aerr != nil {
			s.log.Printf("edit: taking the linked task's @id: %v", aerr)
			adopted = ""
		}
	}
	f, err := readNoteFile(s.ix.Path(rel))
	if err != nil {
		s.editMu.Unlock()
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if adopted != "" && req.Lnum <= len(f.lines) && f.lines[req.Lnum-1] == req.Expect {
		f.lines[req.Lnum-1], req.Expect = adopted, adopted
	}
	var before string
	if req.Lnum >= 1 && req.Lnum <= len(f.lines) {
		before = f.lines[req.Lnum-1]
	}
	lnum, err := s.applyEdit(f, req)
	if err == nil {
		err = f.write()
	}
	// what a task checked here is estimated to earn: its share of its group,
	// or what was left of a group (edit.Groups; 0: from its @size)
	hours := 0.0
	if err == nil && taskOp && lnum >= 1 && lnum <= len(f.lines) {
		was := append([]string(nil), f.lines...)
		was[lnum-1] = before
		if g := s.calibration().groups(was, 0, 0)[lnum]; g != nil && (g.Parent != 0 || !g.Leaf) {
			hours = g.Hours
			if !g.Leaf {
				hours = g.OpenHours
			}
		}
	}
	var synced []string
	if err == nil && taskOp && lnum >= 1 && lnum <= len(f.lines) {
		var serr error
		if synced, serr = s.propagate(rel, lnum, f.lines[lnum-1]); serr != nil {
			s.log.Printf("edit: keeping copies and groups in step: %v", serr)
		}
	}
	s.editMu.Unlock()
	if errors.Is(err, errChanged) {
		s.afterWrite() // pick up whatever changed it
		out := s.noteState(page)
		out["error"] = err.Error()
		writeJSON(w, http.StatusConflict, out)
		return
	}
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error()})
		return
	}
	after := ""
	if req.Op != "delete" && lnum >= 1 && lnum <= len(f.lines) {
		after = f.lines[lnum-1]
	}
	s.recordCompletion(rel, before, after, hours)
	s.afterWrite()
	s.log.Printf("edit %s:%d %s", rel, req.Lnum, req.Op)
	if len(synced) > 0 {
		s.log.Printf("edit: same @id updated in %s", strings.Join(synced, ", "))
	}
	out := s.noteState(page)
	out["ok"], out["lnum"], out["line"] = true, lnum, after
	if page != rel {
		out["lnum"], out["task"] = 0, map[string]any{"rel": rel, "lnum": lnum, "line": after}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) apiInbox(w http.ResponseWriter, r *http.Request) {
	if !s.writableOK(w, r) {
		return
	}
	var req struct {
		Text string `json:"text"`
		Kind string `json:"kind"`
		// set by the web app's offline queue (inbox.js): a capture sent again
		// because its answer was lost is added once
		ID string `json:"id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return
	}
	if req.Kind == "" {
		req.Kind = "task"
	}
	line, err := s.newLine("", req.Kind, req.Text)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error()})
		return
	}
	if len(req.ID) > 64 {
		req.ID = req.ID[:64]
	}
	s.editMu.Lock()
	if prev, ok := s.inboxSent.get(req.ID); ok {
		s.editMu.Unlock()
		writeJSON(w, http.StatusOK, prev)
		return
	}
	path := s.ix.Path(inboxRel)
	f, err := readNoteFile(path)
	if errors.Is(err, os.ErrNotExist) {
		f, err = &noteFile{path: path, lines: []string{"@@Inbox", ""}, final: true, mode: 0o664}, nil
	}
	if err == nil {
		// after the last non-blank line
		end := len(f.lines)
		for end > 0 && strings.TrimSpace(f.lines[end-1]) == "" {
			end--
		}
		if end > 0 && syntax.Parse(f.lines[:end], false).Header.LastLnum >= end {
			f.lines = append(f.lines[:end], "", line) // a blank line after the header
		} else {
			f.lines = append(f.lines[:end], line)
		}
		err = f.write()
	}
	lnum := 0
	if f != nil {
		lnum = len(f.lines)
	}
	out := map[string]any{"ok": true, "rel": inboxRel, "lnum": lnum, "line": line, "url": s.noteURL(inboxRel, lnum)}
	if err == nil {
		s.inboxSent.put(req.ID, out)
	}
	s.editMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	s.afterWrite()
	s.log.Printf("inbox: %s", line)
	writeJSON(w, http.StatusOK, out)
}

// sentIDs remembers the answers to the last inbox captures that carried an
// id, so the offline queue can resend one whose answer never arrived (the
// connection dropped after the write) without adding it twice. Guarded by
// Server.editMu.
type sentIDs struct {
	byID  map[string]map[string]any
	order []string
}

const sentIDsMax = 500

func (c *sentIDs) get(id string) (map[string]any, bool) {
	if id == "" || c.byID == nil {
		return nil, false
	}
	v, ok := c.byID[id]
	return v, ok
}

func (c *sentIDs) put(id string, v map[string]any) {
	if id == "" {
		return
	}
	if c.byID == nil {
		c.byID = map[string]map[string]any{}
	}
	if _, ok := c.byID[id]; !ok {
		c.order = append(c.order, id)
	}
	c.byID[id] = v
	for len(c.order) > sentIDsMax {
		delete(c.byID, c.order[0])
		c.order = c.order[1:]
	}
}

// =============================================================================
// Completions made on the web, until Neovim counts them
// =============================================================================

type webCompletion struct {
	Rel   string    `json:"rel"`
	Title string    `json:"title"`
	At    time.Time `json:"at"`
	// what its XP is estimated from (the project task's, for a calendar copy)
	Size  string  `json:"size,omitempty"`
	P     string  `json:"p,omitempty"`
	I     string  `json:"i,omitempty"`
	Hours float64 `json:"hours,omitempty"` // its share of a task group (else from Size)
}

type completionLog struct {
	mu   sync.Mutex
	path string
	done map[string]webCompletion // @id -> completion
}

// taskKey: a completion is its task's @id, so a calendar copy and its
// project task (the same @id) count once.
func taskKey(line string) string {
	id, _ := edit.Attribute(line, "id")
	return id
}

func (c *completionLog) load() {
	if c.done != nil {
		return
	}
	c.done = map[string]webCompletion{}
	if raw, err := os.ReadFile(c.path); err == nil {
		_ = json.Unmarshal(raw, &c.done)
	}
}

func (c *completionLog) save() {
	if raw, err := json.MarshalIndent(c.done, "", " "); err == nil {
		tmp := c.path + ".tmp"
		if os.WriteFile(tmp, raw, 0o640) == nil {
			_ = os.Rename(tmp, c.path)
		}
	}
}

// projectTaskLine: the project task (not a calendar copy) with this @id, or "".
func (s *Server) projectTaskLine(id string) string {
	if id == "" {
		return ""
	}
	needle := "@id(" + id + ")"
	for _, rel := range s.ix.All() {
		if s.ix.IsArchived(rel) {
			continue
		}
		d := s.ix.Doc(rel)
		if d == nil || !s.isProjectDoc(d) {
			continue
		}
		for i, l := range d.Lines {
			if strings.Contains(l, needle) && !d.InCode(i+1) {
				if it := syntax.ItemOf(l); it != nil && it.Mark != "" {
					return l
				}
			}
		}
	}
	return ""
}

// lineChange: a line a task edit changed besides its own.
type lineChange struct {
	Rel  string
	Lnum int
	Line string
}

// propagate: after rel:lnum became line (checked or reopened), its copies
// follow (syncMirrors), and so do the tasks of its group (edit.Cascade:
// checking a group checks its tasks, the last task checked checks the group,
// a task reopened reopens the groups above it), then their copies, and so
// on. Returns the other notes it changed. Call with editMu held.
func (s *Server) propagate(rel string, lnum int, line string) ([]string, error) {
	queue := []lineChange{{rel, lnum, line}}
	seen := map[string]bool{}
	notes := map[string]bool{}
	var errs []error
	for i := 0; i < len(queue); i++ {
		q := queue[i]
		key := q.Rel + "\x00" + strconv.Itoa(q.Lnum)
		if seen[key] {
			continue
		}
		seen[key] = true
		rels, copies, err := s.syncMirrors(q.Rel, q.Lnum, q.Line)
		if err != nil {
			errs = append(errs, err)
		}
		for _, r := range rels {
			notes[r] = true
		}
		queue = append(queue, copies...)
		f, err := readNoteFile(s.ix.Path(q.Rel))
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if q.Lnum > len(f.lines) || f.lines[q.Lnum-1] != q.Line {
			continue // changed since: leave it
		}
		edits := edit.Cascade(f.lines, q.Lnum, today())
		if len(edits) == 0 {
			continue
		}
		for _, e := range edits {
			f.lines[e.Lnum-1] = e.Line
		}
		if err := f.write(); err != nil {
			errs = append(errs, err)
			continue
		}
		if q.Rel != rel {
			notes[q.Rel] = true
		}
		for _, e := range edits {
			queue = append(queue, lineChange{q.Rel, e.Lnum, e.Line})
		}
	}
	var out []string
	for r := range notes {
		if r != rel {
			out = append(out, r)
		}
	}
	sort.Strings(out)
	return out, errors.Join(errs...)
}

// recordCompletion notes a task completed (or un-completed) on the web.
// hours: what it is estimated to earn when it is in a task group (0: its
// @size, or its project task's).
func (s *Server) recordCompletion(rel, before, after string, hours float64) {
	if s.cfg.DataDir == "" {
		return
	}
	c := &s.completions
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.path == "" {
		c.path = filepath.Join(s.cfg.DataDir, "web_completions.json")
	}
	c.load()
	changed := false
	if k := taskKey(before); k != "" && isDone(before) && !isDone(after) {
		delete(c.done, k)
		changed = true
	}
	if k := taskKey(after); k != "" && isDone(after) && !isDone(before) {
		title := syntax.StripAttributes(after)
		if it := syntax.ItemOf(after); it != nil {
			title = strings.TrimSpace(syntax.StripAttributes(after[it.ContentCol:]))
		}
		// a calendar copy weighs what its project task does
		src := after
		if pt := s.projectTaskLine(k); pt != "" {
			src = pt
			if it := syntax.ItemOf(pt); it != nil {
				title = strings.TrimSpace(syntax.StripAttributes(pt[it.ContentCol:]))
			}
		}
		wc := webCompletion{Rel: rel, Title: title, At: time.Now().UTC(), Hours: hours}
		wc.Size, _ = edit.Attribute(src, "size")
		if wc.Size == "" {
			wc.Size = bareSize(src)
		}
		wc.P, _ = edit.Attribute(src, "p")
		if wc.P == "" {
			wc.P = bareFlag(src, "p")
		}
		wc.I, _ = edit.Attribute(src, "i")
		if wc.I == "" {
			wc.I = bareFlag(src, "i")
		}
		c.done[k] = wc
		changed = true
	}
	if changed {
		c.save()
	}
}

var (
	bareSizeRe = regexp.MustCompile(`(?:^|\s)@(xs|sm|md|lg|xl|[2-5]xl)(?:\s|$)`)
	bareP      = regexp.MustCompile(`(?:^|\s)@p([1-3])(?:\s|$)`)
	bareI      = regexp.MustCompile(`(?:^|\s)@i([1-3])(?:\s|$)`)
)

// bareSize: "@lg" written without @size(...).
func bareSize(line string) string {
	if m := bareSizeRe.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	return ""
}

// bareFlag: "@p1" / "@i2".
func bareFlag(line, key string) string {
	re := bareP
	if key == "i" {
		re = bareI
	}
	if m := re.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	return ""
}

// pendingCompletions: web completions newer than Neovim's last XP summary
// (all of them when there is none); older ones are forgotten.
func (s *Server) pendingCompletions(counted time.Time) []webCompletion {
	if s.cfg.DataDir == "" {
		return nil
	}
	c := &s.completions
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.path == "" {
		c.path = filepath.Join(s.cfg.DataDir, "web_completions.json")
	}
	c.load()
	var out []webCompletion
	pruned := false
	for k, v := range c.done {
		if !counted.IsZero() && !v.At.After(counted) {
			delete(c.done, k)
			pruned = true
			continue
		}
		out = append(out, v)
	}
	if pruned {
		c.save()
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

// editorData: what the note template needs for editing.
func (s *Server) editorData(lines []string) template.JS {
	if !s.cfg.Writable {
		return ""
	}
	raw, _ := json.Marshal(s.lineSources(lines))
	return template.JS(raw)
}
