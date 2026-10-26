package web

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// =============================================================================
// Templates
// =============================================================================

var pageNames = []string{"home", "note", "search", "results", "link", "files", "file", "tags", "tag", "broken", "resources", "graph", "error", "projects", "project", "offline", "okr", "review", "areas", "attributes"}

func (s *Server) parseTemplates() error {
	funcs := template.FuncMap{
		"u":       s.url,
		"asset":   s.assetURL,
		"noteURL": s.noteURL,
		"openURL": s.searchOpenURL,
		"fileURL": s.fileURL,
		"rawURL":  s.rawURL,
		"linkURL": s.linkURL,
		"size":    humanSize,
		"ago":     ago,
		"date":    func(t time.Time) string { return t.Format("2006-01-02 15:04") },
		"title":   s.noteTitle,
		"base":    path.Base,
		"lower":   strings.ToLower,
		"dir": func(rel string) string {
			d := path.Dir(rel)
			if d == "." {
				return ""
			}
			return d
		},
		"inc":      func(n int) int { return n + 1 },
		"siteName": func() string { return s.cfg.Title },
		"srcURL":   s.srcURL,
		"backlinks": func(groups []backGroup, empty string) map[string]any {
			return map[string]any{"Groups": groups, "Empty": empty}
		},
		// project pages
		"hours":   formatHours,
		"minutes": formatMinutes,
		// a template called with several values: (dict "T" . "W" $w)
		"dict": func(kv ...any) map[string]any {
			out := map[string]any{}
			for i := 0; i+1 < len(kv); i += 2 {
				if k, ok := kv[i].(string); ok {
					out[k] = kv[i+1]
				}
			}
			return out
		},
		"taskView": func(page map[string]any, t *webTask) map[string]any {
			return map[string]any{"T": t, "Writable": page["Writable"], "Today": page["Today"]}
		},
	}
	s.pages = map[string]*template.Template{}
	for _, name := range pageNames {
		files := []string{"templates/layout.html", "templates/partials.html", "templates/" + name + ".html"}
		if name == "search" {
			files = append(files, "templates/results.html")
		}
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(templateFS, files...)
		if err != nil {
			return fmt.Errorf("template %s: %w", name, err)
		}
		s.pages[name] = t
	}
	// a slide deck is a page of its own, without the layout
	t, err := template.New("slides.html").Funcs(funcs).ParseFS(templateFS, "templates/slides.html")
	if err != nil {
		return fmt.Errorf("template slides: %w", err)
	}
	s.pages["slides"] = t
	return nil
}

// render executes a page inside the layout (or, for partial requests, just
// its "content" block).
func (s *Server) render(w http.ResponseWriter, r *http.Request, page string, status int, data map[string]any) {
	data["Site"] = s.cfg.Title
	data["Base"] = s.cfg.Base
	data["Nav"] = navOf[page]
	if tab, ok := data["NavTab"].(string); ok && tab != "" {
		data["Nav"] = tab
	}
	if _, ok := data["Query"]; !ok {
		data["Query"] = ""
	}
	t := s.pages[page]
	name := "layout.html"
	switch page {
	case "results":
		name = "results"
	case "slides":
		name = "slides.html"
	}
	var buf bytes.Buffer
	if err := t.ExecuteTemplate(&buf, name, data); err != nil {
		s.log.Printf("render %s: %v", page, err)
		http.Error(w, "render error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = buf.WriteTo(w)
}

// navOf: which top-bar tab a page belongs to.
var navOf = map[string]string{"files": "files", "file": "files", "resources": "files", "tags": "graph", "tag": "graph", "broken": "broken", "graph": "graph", "projects": "projects", "project": "projects", "okr": "okr", "areas": "areas", "review": "review"}

// backGroup is the backlinks from one note or file.
type backGroup struct {
	From     string
	FromNote bool
	Title    string
	Links    []Backlink
}

func (s *Server) groupBacklinks(list []Backlink) []backGroup {
	var groups []backGroup
	for _, b := range list {
		if n := len(groups); n > 0 && groups[n-1].From == b.From {
			groups[n-1].Links = append(groups[n-1].Links, b)
			continue
		}
		title := path.Base(b.From)
		if b.FromNote {
			title = s.noteTitle(b.From)
		}
		groups = append(groups, backGroup{From: b.From, FromNote: b.FromNote, Title: title, Links: []Backlink{b}})
	}
	return groups
}

// srcURL links to where a link was written: the note line, or the file.
func (s *Server) srcURL(from string, fromNote bool, lnum int) string {
	if fromNote {
		return s.noteURL(from, lnum)
	}
	return s.fileURL(from)
}

func (s *Server) notFound(w http.ResponseWriter, r *http.Request, msg string) {
	s.render(w, r, "error", http.StatusNotFound, map[string]any{"Title": "Not found", "Message": msg})
}

func (s *Server) noteTitle(rel string) string {
	if d := s.ix.Doc(rel); d != nil {
		return d.Title()
	}
	return strings.TrimSuffix(path.Base(rel), s.cfg.Ext)
}

func humanSize(n int64) string {
	switch {
	case n < 1024:
		return fmt.Sprintf("%d B", n)
	case n < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(n)/1024)
	case n < 1024*1024*1024:
		return fmt.Sprintf("%.1f MB", float64(n)/(1024*1024))
	}
	return fmt.Sprintf("%.1f GB", float64(n)/(1024*1024*1024))
}

func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	case d < 30*24*time.Hour:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
	return t.Format("2006-01-02")
}

// =============================================================================
// Pages
// =============================================================================

func (s *Server) handleHome(w http.ResponseWriter, r *http.Request) {
	snap := s.current()
	recent := snap.recent
	if len(recent) > 15 {
		recent = recent[:15]
	}
	type row struct {
		Rel     string
		Title   string
		ModTime time.Time
	}
	var rows []row
	for _, rel := range recent {
		if d := s.ix.Doc(rel); d != nil {
			rows = append(rows, row{Rel: rel, Title: d.Title(), ModTime: d.ModTime})
		}
	}
	shown := snap.structure.Unlinked
	if len(shown) > 12 {
		shown = shown[:12]
	}
	calRel := ""
	if d := s.calendarDoc(); d != nil {
		calRel = d.Rel
	}
	// this week's focus projects (the weekly review in reviews.zortex)
	var focusRows []projectRow
	week, focusEarlier := "", false
	if s.reviewsDoc() != nil {
		all := s.allProjects()
		var focus []*webProject
		week, focus, focusEarlier = s.focus(all, time.Now())
		focused := map[*webProject]bool{}
		for _, p := range focus {
			focused[p] = true
		}
		for _, p := range focus {
			focusRows = append(focusRows, s.row(p, focused, nil))
		}
	}
	s.render(w, r, "home", http.StatusOK, map[string]any{
		"XP":             !s.cfg.NoXP,
		"Focus":          focusRows,
		"FocusWeek":      week,
		"FocusEarlier":   focusEarlier,
		"Title":          s.cfg.Title,
		"Home":           true,
		"HasCalendar":    calRel != "" || s.alerts != nil,
		"CalendarRel":    calRel,
		"HasState":       s.alerts != nil,
		"Writable":       s.cfg.Writable,
		"Structure":      snap.structure,
		"StructureShown": shown,
		"Recent":         rows,
		"Notes":          snap.notes,
		"Links":          snap.links,
		"Broken":         len(snap.broken),
		"Tags":           len(snap.tags),
		"Resources":      len(snap.resources),
		"Unlinked":       snap.unlinked[""],
		"Built":          snap.built,
	})
}

func (s *Server) handleNote(w http.ResponseWriter, r *http.Request) {
	rel, ok := cleanRel(r.PathValue("rel"))
	if ok && rel != "" && !s.isNote(rel) {
		if s.ix.Doc(rel+s.cfg.Ext) != nil {
			http.Redirect(w, r, s.noteURL(rel+s.cfg.Ext, 0), http.StatusFound)
			return
		}
	}
	doc := (*notes.Document)(nil)
	if ok && rel != "" {
		doc = s.ix.Doc(rel)
	}
	if doc == nil {
		s.notFound(w, r, "No such note: "+rel)
		return
	}
	if r.URL.Query().Get("view") == "slides" {
		s.handleSlides(w, r, rel)
		return
	}
	s.renderNotePage(w, r, rel, "")
}

// renderNotePage renders note rel; nav is the top-bar tab to mark.
func (s *Server) renderNotePage(w http.ResponseWriter, r *http.Request, rel, nav string) {
	doc := s.ix.Doc(rel)
	if doc == nil {
		s.notFound(w, r, "No such note: "+rel)
		return
	}
	side := s.structureSide(rel)
	if side != nil && nav == "" {
		nav = "graph"
	}
	groups := s.groupBacklinks(s.current().backlinks[rel])
	h := doc.Header()
	aliases := []string{}
	if len(h.Names) > 1 {
		aliases = h.Names[1:]
	}
	s.render(w, r, "note", http.StatusOK, map[string]any{
		"Title":     doc.Title(),
		"Rel":       rel,
		"Crumbs":    s.crumbs(rel),
		"Aliases":   aliases,
		"Tags":      h.Tags,
		"Archived":  s.ix.IsArchived(rel),
		"Body":      s.renderNote(doc),
		"TOC":       toc(doc),
		"Backlinks": groups,
		"BackCount": len(s.current().backlinks[rel]),
		"ModTime":   doc.ModTime,
		"Mod":       doc.ModTime.UnixNano(),
		"Raw":       s.rawURL(rel),
		"Folder":    s.fileURL(path.Dir(rel)),
		"Structure": side,
		"Writable":  s.cfg.Writable,
		"Tracking":  s.tracking(),
		"Src":       s.editorData(doc.Lines),
		"Graph":     s.localGraph(rel),
		"NavTab":    nav,
	})
}

// resultGroup is the search results of one note.
type resultGroup struct {
	Rel      string
	Title    string
	Archived bool
	Items    []resultItem
}

type resultItem struct {
	Line   bool
	Lnum   int
	Crumbs []string // section: ancestors
	Name   string   // section: its own text
	Child  bool
	Text   template.HTML // line: highlighted
}

const maxShown = 300

func (s *Server) searchResults(q, mode string) ([]resultGroup, int) {
	results := s.searchConfig().Query(s.current().search, q, mode)
	var words []string
	if mode == "text" {
		words = []string{syntax.Lower(q)}
	} else {
		for _, t := range search.Tokenize(q) {
			words = append(words, t.Text)
		}
	}
	var groups []resultGroup
	for i, res := range results {
		if i >= maxShown {
			break
		}
		if n := len(groups); n == 0 || groups[n-1].Rel != res.Rel || (res.Type == "line") != groups[n-1].Items[len(groups[n-1].Items)-1].Line {
			groups = append(groups, resultGroup{Rel: res.Rel, Title: s.noteTitle(res.Rel), Archived: res.Archived})
		}
		g := &groups[len(groups)-1]
		item := resultItem{Lnum: res.Lnum}
		if res.Type == "line" {
			item.Line = true
			item.Text = highlight(strings.TrimSpace(res.Line), words)
		} else {
			parts := strings.Split(res.Breadcrumb, " › ")
			item.Name, item.Crumbs, item.Child = parts[len(parts)-1], parts[:len(parts)-1], res.Child
		}
		g.Items = append(g.Items, item)
	}
	return groups, len(results)
}

// searchConfig: the plugin's defaults, ranked by this server's history.
func (s *Server) searchConfig() search.Config {
	c := search.DefaultConfig()
	c.History = s.history
	return c
}

// searchOpenURL: a search result's link, through /search/open so opening
// it is remembered (the note's URL when there is no history).
func (s *Server) searchOpenURL(rel string, lnum int, section bool) string {
	if s.history == nil {
		return s.noteURL(rel, lnum)
	}
	v := url.Values{"rel": {rel}, "lnum": {strconv.Itoa(lnum)}}
	if section {
		v.Set("section", "1")
	}
	return s.url("/search/open?" + v.Encode())
}

// handleSearchOpen: GET /search/open?rel=&lnum=&section= records the result
// in the search history and goes to it.
func (s *Server) handleSearchOpen(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	rel := q.Get("rel")
	lnum, _ := strconv.Atoi(q.Get("lnum"))
	doc := s.ix.Doc(rel)
	if doc == nil {
		s.notFound(w, r, "No note "+rel+".")
		return
	}
	if s.history != nil {
		var crumbs []string
		if q.Get("section") == "1" {
			for n := doc.NodeStartingAt(lnum); n != nil && !n.IsRoot(); n = n.Parent {
				crumbs = append(crumbs, n.Breadcrumb(" › "))
			}
		}
		if err := s.history.Record(rel, crumbs, time.Now()); err != nil {
			s.log.Printf("search history: %v", err)
		}
	}
	http.Redirect(w, r, s.noteURL(rel, lnum), http.StatusFound)
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	mode := r.URL.Query().Get("mode")
	if mode != "article" && mode != "text" {
		mode = "section"
	}
	var groups []resultGroup
	total := 0
	if strings.TrimSpace(q) != "" || mode == "article" {
		groups, total = s.searchResults(q, mode)
	}
	data := map[string]any{
		"Title":  "Search",
		"Query":  q,
		"Mode":   mode,
		"Groups": groups,
		"Total":  total,
		"Shown":  min(total, maxShown),
	}
	if r.URL.Query().Get("partial") == "1" {
		s.render(w, r, "results", http.StatusOK, data)
		return
	}
	if q != "" {
		data["Title"] = q + " · Search"
	}
	s.render(w, r, "search", http.StatusOK, data)
}

// linkDef is the link a ?to= parameter names: "P/#1.4" and "[P/#1.4]" are
// "[P/#1.4]"; tag searches stay "@[R/rust]".
func linkDef(to string) string {
	if strings.HasPrefix(to, "@[") {
		return to
	}
	return "[" + strings.TrimSuffix(strings.TrimPrefix(to, "["), "]") + "]"
}

// localLink: the link resolves in the note it's in ([/#Heading], or a tag
// search without a scope).
func localLink(link string) bool {
	if strings.HasPrefix(link, "@[") {
		inner := strings.TrimSuffix(strings.TrimPrefix(link, "@["), "]")
		return strings.HasPrefix(inner, "/") || !strings.Contains(inner, "/")
	}
	return strings.HasPrefix(strings.TrimPrefix(link, "["), "/")
}

func (s *Server) handleLink(w http.ResponseWriter, r *http.Request) {
	def := r.URL.Query().Get("to")
	fromRel := r.URL.Query().Get("from")
	var opts links.Options
	if fromRel != "" {
		opts.From = s.ix.Doc(fromRel)
	}
	link := linkDef(def)
	results, err := links.Resolve(s.ix, link, opts)
	if err != nil && opts.From == nil && localLink(link) {
		// say why instead of the resolver's "No buffer to resolve a local link in"
		if fromRel != "" {
			err = errors.New("This server has no note " + fromRel + " to resolve " + link + " in (not synced yet, or a different notes folder?)")
		} else {
			err = errors.New(link + " resolves in the note it's written in, and the request didn't say which (from=)")
		}
	}
	follow := len(results) > 0 && results[0].Link != nil
	if err == nil && len(results) == 1 {
		href := s.noteURL(results[0].Doc.Rel, results[0].Lnum)
		if follow {
			if h, ok := s.followHref(results[0], 1); ok {
				href = h
			}
		}
		http.Redirect(w, r, href, http.StatusFound)
		return
	}
	type target struct {
		Rel, Title, Breadcrumb, Line string
		Lnum                         int
		Href                         string // > links: where the matched link goes
	}
	var targets []target
	for _, res := range results {
		bc := ""
		if n := res.Doc.NodeAt(res.Lnum); n != nil && !n.IsRoot() {
			bc = n.Breadcrumb(" › ")
		}
		t := target{Rel: res.Doc.Rel, Title: res.Doc.Title(), Breadcrumb: bc, Line: strings.TrimSpace(res.Doc.Lines[res.Lnum-1]), Lnum: res.Lnum}
		if follow {
			t.Title = links.SpanText(res.Link)
			t.Href, _ = s.followHref(res, 1)
		}
		targets = append(targets, t)
	}
	status := http.StatusOK
	msg := ""
	if err != nil {
		status, msg = http.StatusNotFound, err.Error()
	}
	table := template.HTML("")
	if strings.HasPrefix(link, "@[") && err == nil {
		table = template.HTML(s.tagTableHTML(opts.From, strings.TrimSuffix(strings.TrimPrefix(link, "@["), "]")))
	}
	s.render(w, r, "link", status, map[string]any{
		"Table":   table,
		"Title":   link,
		"Def":     def,
		"Link":    link,
		"Tags":    strings.HasPrefix(link, "@["),
		"From":    fromRel,
		"Targets": targets,
		"Follow":  follow,
		"Error":   msg,
	})
}

func (s *Server) handleTags(w http.ResponseWriter, r *http.Request) {
	s.render(w, r, "tags", http.StatusOK, map[string]any{"Title": "Tags", "Tags": s.current().tags})
}

func (s *Server) handleTag(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	for _, t := range s.current().tags {
		if strings.EqualFold(t.Name, name) {
			s.render(w, r, "tag", http.StatusOK, map[string]any{"Title": "@" + t.Name, "Tag": t, "Targets": s.tagTargets(t.Name)})
			return
		}
	}
	s.notFound(w, r, "No notes are tagged @"+name)
}

func (s *Server) handleBroken(w http.ResponseWriter, r *http.Request) {
	all := s.current().broken
	var broken []Broken
	for _, b := range all {
		if !isTagLink(b) { // [@Tag] links: with the tags
			broken = append(broken, b)
		}
	}
	sort.SliceStable(broken, func(i, j int) bool { return broken[i].From < broken[j].From })
	snap := s.current()
	orphans, structureOnly := s.orphanNotes(snap)
	tags := s.tagProblems(all)
	s.render(w, r, "broken", http.StatusOK, map[string]any{
		"Title":  "Broken links",
		"Broken": broken,
		// every list is shown only when it has something in it
		"Clean":         len(broken) == 0 && len(orphans) == 0 && len(tags.Searches) == 0 && len(tags.Links) == 0,
		"Tags":          tags,
		"Orphans":       orphans,
		"StructureOnly": structureOnly,
		"HasStructure":  len(snap.structure.Sources) > 0,
		"Roots":         snap.structure.Roots,
		"Unlinked":      snap.unlinked[""],
	})
}

// orphanRow is a note on /broken that nothing reaches.
type orphanRow struct {
	Rel, Title, Dir string
	ModTime         time.Time
}

// orphanNotes: the notes outside the structure that no other note (or
// Markdown file) links to either, by folder then name, and how many notes
// are outside the structure but linked from somewhere.
func (s *Server) orphanNotes(snap *snapshot) ([]orphanRow, int) {
	var out []orphanRow
	linkedOnly := 0
	candidates := snap.structure.Unlinked
	if len(snap.structure.Sources) == 0 { // no structure yet: every note
		for _, rel := range s.ix.Catalog().Files(false) {
			if s.isNote(rel) {
				candidates = append(candidates, rel)
			}
		}
	}
	for _, rel := range candidates {
		linked := false
		for _, b := range snap.backlinks[rel] {
			if b.From != rel {
				linked = true
				break
			}
		}
		if linked {
			linkedOnly++
			continue
		}
		d := path.Dir(rel)
		if d == "." {
			d = ""
		}
		row := orphanRow{Rel: rel, Title: s.noteTitle(rel), Dir: d}
		if st, err := os.Stat(s.ix.Path(rel)); err == nil {
			row.ModTime = st.ModTime()
		}
		out = append(out, row)
	}
	return out, linkedOnly
}

// =============================================================================
// JSON
// =============================================================================

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// apiSearch: GET /api/search?q=&mode=&limit= -> [{type, rel, lnum, breadcrumb?, score?, child?, line?, url}]
func (s *Server) apiSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	limit := 50
	fmt.Sscan(r.URL.Query().Get("limit"), &limit)
	type out struct {
		Type       string `json:"type"`
		Rel        string `json:"rel"`
		Lnum       int    `json:"lnum"`
		Breadcrumb string `json:"breadcrumb,omitempty"`
		Score      int    `json:"score,omitempty"`
		Child      bool   `json:"child,omitempty"`
		Line       string `json:"line,omitempty"`
		URL        string `json:"url"`
	}
	res := []out{}
	for i, x := range s.searchConfig().Query(s.current().search, q, r.URL.Query().Get("mode")) {
		if limit > 0 && i >= limit {
			break
		}
		res = append(res, out{x.Type, x.Rel, x.Lnum, x.Breadcrumb, x.Score, x.Child, x.Line, s.noteURL(x.Rel, x.Lnum)})
	}
	writeJSON(w, http.StatusOK, res)
}

// apiResolve: GET /api/resolve?to=&from= -> {results: [{rel, lnum, col, url, follow?}], error?}
func (s *Server) apiResolve(w http.ResponseWriter, r *http.Request) {
	var opts links.Options
	if from := r.URL.Query().Get("from"); from != "" {
		opts.From = s.ix.Doc(from)
	}
	results, err := links.Resolve(s.ix, linkDef(r.URL.Query().Get("to")), opts)
	type res struct {
		Rel  string `json:"rel"`
		Lnum int    `json:"lnum"`
		Col  int    `json:"col"`
		URL  string `json:"url"`
		// > links: where the matched link goes
		Follow string `json:"follow,omitempty"`
	}
	body := map[string]any{"results": []res{}}
	list := []res{}
	for _, x := range results {
		item := res{Rel: x.Doc.Rel, Lnum: x.Lnum, Col: x.Col, URL: s.noteURL(x.Doc.Rel, x.Lnum)}
		if x.Link != nil {
			item.Follow, _ = s.followHref(x, 1)
		}
		list = append(list, item)
	}
	body["results"] = list
	status := http.StatusOK
	if err != nil {
		body["error"] = err.Error()
		status = http.StatusNotFound
	}
	writeJSON(w, status, body)
}

// apiBacklinks: GET /api/backlinks?rel= -> [{from, lnum, line, breadcrumb, def, to_lnum}]
func (s *Server) apiBacklinks(w http.ResponseWriter, r *http.Request) {
	type out struct {
		From       string `json:"from"`
		Lnum       int    `json:"lnum"`
		Line       string `json:"line"`
		Breadcrumb string `json:"breadcrumb"`
		Def        string `json:"def"`
		ToLnum     int    `json:"to_lnum"`
	}
	list := []out{}
	for _, b := range s.current().backlinks[r.URL.Query().Get("rel")] {
		list = append(list, out{b.From, b.Lnum, b.Line, b.Breadcrumb, b.Def, b.ToLnum})
	}
	writeJSON(w, http.StatusOK, list)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	snap := s.current()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"notes":   snap.notes,
		"links":   snap.links,
		"broken":  len(snap.broken),
		"indexed": snap.built.Format(time.RFC3339),
		"took_ms": snap.took.Milliseconds(),
		"data":    s.cfg.DataDir != "", // notifications and the pomodoro need it
		"ntfy":    s.cfg.Ntfy.Enabled(),
		"xp":      !s.cfg.NoXP,
	})
}
