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
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Editing (zortex serve -writable): small, line-level changes to notes from
// the web, for when you're away from Neovim:
//
//	POST /api/edit   {rel, lnum, expect, op, text?, kind?}
//	  op open | done | toggle | text    task state (app/edit, as Neovim does it)
//	     set                            replace the line's text after its marker
//	     delete                         remove the line
//	     insert                         add a line after lnum (kind task | note | text)
//	POST /api/inbox  {text, kind}       append a task or a note to inbox.zortex
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
		line, err := edit.Line(f.lines[i], req.Op, today(), s.newID)
		if err != nil {
			return 0, err
		}
		f.lines[i] = line
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
	s.ix.Scan()
	go s.rebuild(s.scanResources())
}

// noteState: what the page needs to redraw a note after an edit.
func (s *Server) noteState(rel string) map[string]any {
	doc := s.ix.Doc(rel)
	if doc == nil {
		return map[string]any{}
	}
	return map[string]any{"body": s.renderNote(doc), "src": s.lineSources(doc.Lines)}
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
	rel, ok := cleanRel(req.Rel)
	if !ok || rel == "" || !s.isNote(rel) || s.ix.Doc(rel) == nil {
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
	var before string
	if req.Lnum >= 1 && req.Lnum <= len(f.lines) {
		before = f.lines[req.Lnum-1]
	}
	lnum, err := s.applyEdit(f, req)
	if err == nil {
		err = f.write()
	}
	s.editMu.Unlock()
	if errors.Is(err, errChanged) {
		s.afterWrite() // pick up whatever changed it
		out := s.noteState(rel)
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
	s.recordCompletion(rel, before, after)
	s.afterWrite()
	s.log.Printf("edit %s:%d %s", rel, req.Lnum, req.Op)
	out := s.noteState(rel)
	out["ok"], out["lnum"], out["line"] = true, lnum, after
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) apiInbox(w http.ResponseWriter, r *http.Request) {
	if !s.writableOK(w, r) {
		return
	}
	var req struct {
		Text string `json:"text"`
		Kind string `json:"kind"`
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
	s.editMu.Lock()
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
	s.editMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	s.afterWrite()
	s.log.Printf("inbox: %s", line)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rel": inboxRel, "lnum": lnum, "line": line, "url": s.noteURL(inboxRel, lnum)})
}

// =============================================================================
// Completions made on the web, until Neovim counts them
// =============================================================================

type webCompletion struct {
	Rel   string    `json:"rel"`
	Title string    `json:"title"`
	At    time.Time `json:"at"`
}

type completionLog struct {
	mu   sync.Mutex
	path string
	done map[string]webCompletion // rel#id -> completion
}

func taskKey(rel, line string) string {
	id, _ := edit.Attribute(line, "id")
	if id == "" {
		return ""
	}
	return rel + "#" + id
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

// recordCompletion notes a task completed (or un-completed) on the web.
func (s *Server) recordCompletion(rel, before, after string) {
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
	if k := taskKey(rel, before); k != "" && isDone(before) && !isDone(after) {
		delete(c.done, k)
		changed = true
	}
	if k := taskKey(rel, after); k != "" && isDone(after) && !isDone(before) {
		title := syntax.StripAttributes(after)
		if it := syntax.ItemOf(after); it != nil {
			title = strings.TrimSpace(syntax.StripAttributes(after[it.ContentCol:]))
		}
		c.done[k] = webCompletion{Rel: rel, Title: title, At: time.Now().UTC()}
		changed = true
	}
	if changed {
		c.save()
	}
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
