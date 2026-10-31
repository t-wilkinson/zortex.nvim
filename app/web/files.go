package web

import (
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
)

// The file browser lists every file in the notes folder. Hidden folders
// (.z, .git, .stversions) and Syncthing artefacts are never shown, and notes
// with a generated name (2026-10-15.042.zortex, from "create note" in
// search) only with ?all=1.

var extraTypes = map[string]string{
	".pdf": "application/pdf", ".epub": "application/epub+zip", ".md": "text/markdown",
	".markdown": "text/markdown", ".org": "text/plain", ".txt": "text/plain", ".log": "text/plain",
	".csv": "text/csv", ".tsv": "text/tab-separated-values", ".json": "application/json",
	".yaml": "text/plain", ".yml": "text/plain", ".toml": "text/plain", ".lua": "text/plain",
	".py": "text/plain", ".go": "text/plain", ".rs": "text/plain", ".sh": "text/plain",
	".nix": "text/plain", ".tex": "text/plain", ".bib": "text/plain", ".zortex": "text/plain",
	".webp": "image/webp", ".avif": "image/avif", ".heic": "image/heic", ".svg": "image/svg+xml",
	".mp4": "video/mp4", ".m4v": "video/mp4", ".webm": "video/webm", ".mkv": "video/x-matroska",
	".mov": "video/quicktime", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".ogg": "audio/ogg",
	".opus": "audio/ogg", ".flac": "audio/flac", ".wav": "audio/wav",
	".html": "text/html", ".htm": "text/html", ".xml": "application/xml",
	".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
}

func mimeOf(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if t, ok := extraTypes[ext]; ok {
		return t
	}
	if t := mime.TypeByExtension(ext); t != "" {
		return t
	}
	return "application/octet-stream"
}

// viewKind: how the viewer shows a file.
func viewKind(mimeType string) string {
	base := strings.SplitN(mimeType, ";", 2)[0]
	switch {
	case base == "application/pdf":
		return "pdf"
	case base == "text/html" || base == "image/svg+xml":
		return "html" // sandboxed frame
	case strings.HasPrefix(base, "image/"):
		return "image"
	case strings.HasPrefix(base, "video/"):
		return "video"
	case strings.HasPrefix(base, "audio/"):
		return "audio"
	case strings.HasPrefix(base, "text/"), base == "application/json", base == "application/xml":
		return "text"
	}
	return "other"
}

// activeType: served with a sandbox CSP so it can't run script on our origin.
func activeType(mimeType string) bool {
	base := strings.SplitN(mimeType, ";", 2)[0]
	return base == "text/html" || base == "image/svg+xml" || base == "application/xml" ||
		base == "text/xml" || strings.Contains(base, "javascript")
}

// sandbox is the sandbox an active file runs in: the iframe's sandbox
// attribute and the CSP sandbox at /raw. HTML may run script with
// Config.HTMLScripts, still in an opaque origin (no allow-same-origin).
func (s *Server) sandbox(mimeType string) string {
	if s.cfg.HTMLScripts && strings.SplitN(mimeType, ";", 2)[0] == "text/html" {
		return "allow-scripts"
	}
	return ""
}

func isSyncArtifact(name string) bool {
	return strings.HasPrefix(name, ".syncthing.") || notes.IsConflictCopy(name) ||
		strings.HasSuffix(name, ".tmp") || strings.HasPrefix(name, "~syncthing~")
}

// entry is a row of a folder listing.
type entry struct {
	Name     string
	Rel      string
	Dir      bool
	Note     bool
	Title    string // note title (article name) or file name
	Size     int64
	ModTime  time.Time
	Kind     string
	Hidden   bool // a note with a generated name (shown with ?all=1)
	Resource bool // tracked resource (see resources.go)
	Links    int  // resource: links to it
	Unlinked int  // folder: unlinked resources inside it
	Sub      bool // a folder of z/ listed at the top level (z/books)
}

// resolvePath maps a rel path to an absolute path inside the folder,
// refusing anything (including symlinks) that leads outside it.
func (s *Server) resolvePath(rel string) (string, os.FileInfo, bool) {
	rel, ok := cleanRel(rel)
	if !ok {
		return "", nil, false
	}
	p := s.ix.Path(rel)
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", nil, false
	}
	root, err := filepath.EvalSymlinks(s.ix.Root)
	if err != nil {
		return "", nil, false
	}
	if real != root && !strings.HasPrefix(real, root+string(filepath.Separator)) {
		return "", nil, false
	}
	st, err := os.Stat(real)
	if err != nil {
		return "", nil, false
	}
	return real, st, true
}

func (s *Server) listDir(rel string, all bool) ([]entry, int, error) {
	abs, _, ok := s.resolvePath(rel)
	if !ok {
		return nil, 0, os.ErrNotExist
	}
	des, err := os.ReadDir(abs)
	if err != nil {
		return nil, 0, err
	}
	var out []entry
	hidden := 0
	for _, de := range des {
		name := de.Name()
		if strings.HasPrefix(name, ".") || isSyncArtifact(name) {
			continue
		}
		erel := name
		if rel != "" {
			erel = rel + "/" + name
		}
		info, err := de.Info()
		if err != nil {
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 {
			if _, st, ok := s.resolvePath(erel); ok {
				info = st
			} else {
				continue
			}
		}
		e := entry{Name: name, Rel: erel, Dir: info.IsDir(), Size: info.Size(), ModTime: info.ModTime(), Title: name}
		snap := s.current()
		if e.Dir {
			e.Unlinked = snap.unlinked[erel]
		} else if s.isResource(erel) {
			e.Resource, e.Links = true, len(snap.fileBacklinks[erel])
		}
		resKind := ""
		if e.Resource {
			resKind = resourceKind(extOf(name))
		}
		if !e.Dir {
			e.Note = s.isNote(name)
			e.Kind = viewKind(mimeOf(name))
			if resKind == "book" || resKind == "document" {
				e.Kind = resKind // icons; the viewer has no preview for these
			}
			if e.Note {
				e.Kind = "note"
				if d := s.ix.Doc(erel); d != nil {
					e.Title = d.Title()
				}
			}
			if e.Note && generatedName(name, s.cfg.Ext) {
				e.Hidden = true
				hidden++
				if !all {
					continue
				}
			}
		}
		out = append(out, e)
	}
	listSort{By: "name", Order: "asc"}.apply(out)
	return out, hidden, nil
}

// listSort orders a folder listing: ?sort=name|modified&order=asc|desc.
// Folders always come first; notes sort by their article name (@@Name). The default is name, ascending; modified time
// starts newest first.
type listSort struct {
	By    string // "name" | "modified"
	Order string // "asc" | "desc"
}

func parseListSort(q url.Values) listSort {
	ls := listSort{By: "name", Order: "asc"}
	if q.Get("sort") == "modified" {
		ls = listSort{By: "modified", Order: "desc"}
	}
	if o := q.Get("order"); o == "asc" || o == "desc" {
		ls.Order = o
	}
	return ls
}

func (ls listSort) apply(entries []entry) {
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.Dir != b.Dir {
			return a.Dir
		}
		// notes by their article name (what the listing shows), files by name
		an, bn := strings.ToLower(a.Title), strings.ToLower(b.Title)
		if an == bn {
			an, bn = strings.ToLower(a.Name), strings.ToLower(b.Name)
		}
		less, equal := an < bn, an == bn
		if ls.By == "modified" && !a.ModTime.Equal(b.ModTime) {
			less, equal = a.ModTime.Before(b.ModTime), false
		}
		if equal {
			return false
		}
		return less == (ls.Order == "asc")
	})
}

// query is the URL query that keeps this order ("" for the default).
func (ls listSort) query() string {
	if ls == (listSort{By: "name", Order: "asc"}) {
		return ""
	}
	return "sort=" + ls.By + "&order=" + ls.Order
}

// sortHeader is a clickable column header.
type sortHeader struct {
	URL   string
	Arrow string // "↑", "↓" on the active column
	Aria  string // aria-sort value
}

// header links a column: the active one flips its order, another one starts
// at its natural order.
func (ls listSort) header(by, base string, extra url.Values) sortHeader {
	next := listSort{By: by, Order: "asc"}
	if by == "modified" {
		next.Order = "desc"
	}
	h := sortHeader{Aria: "none"}
	if ls.By == by {
		next.Order = map[string]string{"asc": "desc", "desc": "asc"}[ls.Order]
		h.Arrow = map[string]string{"asc": "↑", "desc": "↓"}[ls.Order]
		h.Aria = map[string]string{"asc": "ascending", "desc": "descending"}[ls.Order]
	}
	h.URL = withQuery(base, next, extra)
	return h
}

// withQuery is base plus the sort (when not the default) and extra values.
func withQuery(base string, ls listSort, extra url.Values) string {
	q := url.Values{}
	for k, v := range extra {
		q[k] = v
	}
	if ls.query() != "" {
		q.Set("sort", ls.By)
		q.Set("order", ls.Order)
	}
	if len(q) == 0 {
		return base
	}
	return base + "?" + q.Encode()
}

// crumb is a breadcrumb link.
type crumb struct {
	Name string
	URL  string
}

func (s *Server) crumbs(rel string) []crumb {
	out := []crumb{{Name: "notes", URL: s.fileURL("")}}
	if rel == "" {
		return out
	}
	parts := strings.Split(rel, "/")
	for i := range parts {
		out = append(out, crumb{Name: parts[i], URL: s.fileURL(strings.Join(parts[:i+1], "/"))})
	}
	return out
}

func (s *Server) handleFiles(w http.ResponseWriter, r *http.Request) {
	rel, ok := cleanRel(r.PathValue("rel"))
	if !ok {
		s.notFound(w, r, "No such file")
		return
	}
	_, st, ok := s.resolvePath(rel)
	if !ok {
		s.notFound(w, r, "No such file: "+rel)
		return
	}
	if !st.IsDir() {
		if s.isNote(rel) {
			if wantsJSON(r) {
				http.Redirect(w, r, s.url("/api/n/"+escapePath(rel)), http.StatusFound)
				return
			}
			http.Redirect(w, r, s.noteURL(rel, 0), http.StatusFound)
			return
		}
		s.fileView(w, r, rel, st)
		return
	}
	if s.isResourceView(r, rel) {
		s.resourceView(w, r, rel)
		return
	}
	all := r.URL.Query().Get("all") == "1"
	entries, hidden, err := s.listDir(rel, all)
	if err != nil {
		s.notFound(w, r, "Can't read folder: "+rel)
		return
	}
	if rel == "" {
		// z/'s folders (books, feeds, archives) one click away, under z/
		entries = append(entries, s.zFolders()...)
	}
	ls := parseListSort(r.URL.Query())
	ls.apply(entries)
	var extra url.Values
	if all {
		extra = url.Values{"all": {"1"}}
	}
	keep := ""
	if q := ls.query(); q != "" {
		keep = "?" + q
	}
	crumbs := s.crumbs(rel)
	for i := range crumbs {
		crumbs[i].URL += keep
	}
	title := "notes"
	if rel != "" {
		title = path.Base(rel)
	}
	resources := 0
	for _, res := range s.current().resources {
		if rel == "" || strings.HasPrefix(res.Rel, rel+"/") {
			resources++
		}
	}
	s.render(w, r, "files", http.StatusOK, map[string]any{
		"Unlinked":  s.current().unlinked[rel],
		"Resources": resources,
		"Title":     title,
		"Rel":       rel,
		"Crumbs":    crumbs,
		"Entries":   entries,
		"Hidden":    hidden,
		"All":       all,
		"Keep":      keep, // appended to folder links: subfolders keep the order
		"SortName":  ls.header("name", s.fileURL(rel), extra),
		"SortTime":  ls.header("modified", s.fileURL(rel), extra),
		"ShowAll":   withQuery(s.fileURL(rel), ls, url.Values{"all": {"1"}}),
		"Named":     withQuery(s.fileURL(rel), ls, nil),
	})
}

// generatedRe matches the names "create note" gives a note: a date and a
// number (2026-10-15.042).
var generatedRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\.\d{3}$`)

// generatedName reports whether a note's file name was generated rather than
// chosen.
func generatedName(name, ext string) bool {
	return generatedRe.MatchString(strings.TrimSuffix(name, ext))
}

const maxTextView = 1 << 20

// fileView shows a file. HTML and Markdown are shown rendered (HTML in a
// sandboxed frame, Markdown like a note); ?source=1 shows their text.
func (s *Server) fileView(w http.ResponseWriter, r *http.Request, rel string, st os.FileInfo) {
	mt := mimeOf(rel)
	kind := viewKind(mt)
	if isMarkdown(rel) {
		kind = "markdown"
	}
	data := map[string]any{
		"Title":   path.Base(rel),
		"Rel":     rel,
		"Crumbs":  s.crumbs(rel),
		"Mime":    mt,
		"Size":    st.Size(),
		"ModTime": st.ModTime(),
		"Raw":     s.rawURL(rel),
		"Sandbox": s.sandbox(mt),
	}
	if (kind == "html" || kind == "markdown") && strings.HasPrefix(mt, "text/") {
		if r.URL.Query().Get("source") == "1" {
			kind = "text"
			data["Rendered"] = s.fileURL(rel)
		} else {
			data["Source"] = s.fileURL(rel) + "?source=1"
		}
	}
	// an HTML document (notes/documents.go): the page, or its text as the
	// notes read it (where links to its headings land)
	if s.ix.DocumentKind(rel) == "html" {
		data["Page"] = s.fileURL(rel)
		data["Readable"] = s.fileURL(rel) + "?view=readable"
		if r.URL.Query().Get("view") == "readable" {
			if doc := s.ix.Doc(rel); doc != nil {
				kind = "readable"
				data["Body"] = s.renderNote(doc)
			}
		}
	}
	data["Kind"] = kind
	if s.isResource(rel) || s.ix.DocumentKind(rel) != "" {
		links := s.current().fileBacklinks[rel]
		data["Resource"] = true
		data["Backlinks"] = s.groupBacklinks(links)
		data["BackCount"] = len(links)
	}
	if kind == "text" || kind == "markdown" {
		abs, _, _ := s.resolvePath(rel)
		if f, err := os.Open(abs); err == nil {
			buf, _ := io.ReadAll(io.LimitReader(f, maxTextView+1))
			f.Close()
			data["Truncated"] = len(buf) > maxTextView
			if len(buf) > maxTextView {
				buf = buf[:maxTextView]
			}
			text := strings.ToValidUTF8(string(buf), string(utf8.RuneError))
			if kind == "markdown" {
				data["Body"] = s.renderMarkdown(rel, text)
			} else {
				data["Text"] = text
			}
		}
	}
	s.render(w, r, "file", http.StatusOK, data)
}

// handleRaw serves a file as is: ranges and conditional requests (video,
// PDFs), ?download=1 for an attachment, and a sandbox CSP for types that
// could run script.
func (s *Server) handleRaw(w http.ResponseWriter, r *http.Request) {
	rel, ok := cleanRel(r.PathValue("rel"))
	abs, st, found := s.resolvePath(rel)
	if !ok || !found || st.IsDir() {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(abs)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	mt := mimeOf(rel)
	if strings.HasPrefix(mt, "text/") && !strings.Contains(mt, "charset") {
		mt += "; charset=utf-8"
	}
	h := w.Header()
	h.Set("Content-Type", mt)
	h.Set("Cache-Control", "private, max-age=0, must-revalidate")
	if activeType(mt) {
		h.Set("Content-Security-Policy", strings.TrimSpace("sandbox "+s.sandbox(mt)))
	}
	disp := "inline"
	if r.URL.Query().Get("download") == "1" {
		disp = "attachment"
	}
	h.Set("Content-Disposition", disp+`; filename*=UTF-8''`+urlPathEscape(path.Base(rel)))
	http.ServeContent(w, r, path.Base(rel), st.ModTime(), f)
}

func urlPathEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.IndexByte("-._~", c) >= 0 {
			b.WriteByte(c)
		} else {
			b.WriteString("%" + strings.ToUpper(string("0123456789abcdef"[c>>4])+string("0123456789abcdef"[c&15])))
		}
	}
	return b.String()
}
