package web

import (
	"bufio"
	"hash/fnv"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Resources are the non-note files people link to from notes: PDFs, books,
// images, media and office documents (Config.ResourceExts). The server
// tracks which notes (and Markdown files) link to each one, so a file page
// shows its backlinks and /resources lists the files nothing links to.
//
// A file is referenced by a zortex link to a path ([z/books/tt.pdf],
// [./img.png]), a markdown link ([TT](z/books/tt.pdf)) or a bare path
// (./scan.pdf). In notes, "./" and "../" are relative to the note and other
// paths to the notes folder (as following a link in Neovim does); Markdown
// files resolve relative paths from their own folder first. A bare file name
// ([tt.pdf]) resolves when exactly one resource has that name.

// DefaultResourceExts: extensions of the files tracked as resources.
var DefaultResourceExts = []string{
	"pdf",
	"epub", "djvu", "mobi", "azw3", "cbz", "cbr",
	"png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tif", "tiff",
	"mp4", "m4v", "mkv", "mov", "webm", "avi",
	"mp3", "m4a", "ogg", "opus", "flac", "wav",
	"doc", "docx", "odt", "rtf", "ppt", "pptx", "odp", "key", "xls", "xlsx", "ods", "pages", "numbers",
}

// resourceKind groups extensions for display and filtering.
func resourceKind(ext string) string {
	switch ext {
	case "pdf":
		return "pdf"
	case "epub", "djvu", "mobi", "azw3", "cbz", "cbr":
		return "book"
	case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tif", "tiff":
		return "image"
	case "mp4", "m4v", "mkv", "mov", "webm", "avi":
		return "video"
	case "mp3", "m4a", "ogg", "opus", "flac", "wav":
		return "audio"
	}
	return "document"
}

var resourceKinds = []string{"pdf", "book", "image", "video", "audio", "document"}

// Files that can link to resources besides notes.
var linkingExts = map[string]bool{"md": true, "markdown": true}

const maxLinkingFile = 1 << 20

type resource struct {
	Rel     string
	Kind    string
	Size    int64
	ModTime time.Time
}

func extOf(name string) string { return strings.ToLower(strings.TrimPrefix(path.Ext(name), ".")) }

// isResource reports whether rel has a resource extension.
func (s *Server) isResource(rel string) bool { return s.resExts[extOf(rel)] }

// scanResources walks the folder for resources and Markdown files (skipping
// hidden folders and Syncthing artefacts); the fingerprint changes when any
// of them is added, removed or modified.
func (s *Server) scanResources() (res []resource, linking []string, fingerprint uint64) {
	h := fnv.New64a()
	root := s.ix.Root
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if p != root && strings.HasPrefix(name, ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(name, ".") || isSyncArtifact(name) || !d.Type().IsRegular() {
			return nil
		}
		ext := extOf(name)
		isRes, isLinking := s.resExts[ext], linkingExts[ext]
		if !isRes && !isLinking {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		h.Write([]byte(rel + "\x00" + strconv.FormatInt(info.Size(), 10) + "\x00" + strconv.FormatInt(info.ModTime().UnixNano(), 10) + "\n"))
		if isRes {
			res = append(res, resource{Rel: rel, Kind: resourceKind(ext), Size: info.Size(), ModTime: info.ModTime()})
		}
		if isLinking && info.Size() <= maxLinkingFile {
			linking = append(linking, rel)
		}
		return nil
	})
	sort.Slice(res, func(i, j int) bool { return res[i].Rel < res[j].Rel })
	return res, linking, h.Sum64()
}

// byBasename indexes resources by lower-cased file name, for bare-name links.
func byBasename(res []resource) map[string][]string {
	out := map[string][]string{}
	for _, r := range res {
		k := strings.ToLower(path.Base(r.Rel))
		out[k] = append(out[k], r.Rel)
	}
	return out
}

// localRef resolves a path written in fromRel to a rel path in the folder.
// local is false for URLs and anchors; found reports whether the file (or
// folder) exists. dirFirst: plain relative paths are tried from fromRel's
// folder before the notes folder (Markdown files).
func (s *Server) localRef(fromRel, p string, dirFirst bool, names map[string][]string) (rel, frag string, local, found bool) {
	if p == "" || strings.Contains(p, "://") || strings.HasPrefix(p, "mailto:") || strings.HasPrefix(p, "#") || strings.HasPrefix(p, "~") {
		return "", "", false, false
	}
	if i := strings.IndexByte(p, '#'); i >= 0 {
		p, frag = p[:i], p[i:]
	}
	exists := func(r string) bool {
		r, ok := cleanRel(r)
		if !ok || r == "" {
			return false
		}
		_, err := os.Stat(s.ix.Path(r))
		return err == nil
	}
	var candidates []string
	dir := path.Dir(fromRel)
	switch {
	case strings.HasPrefix(p, "./") || strings.HasPrefix(p, "../"):
		candidates = []string{path.Join(dir, p)}
	case strings.HasPrefix(p, "/"):
		candidates = []string{path.Clean(p[1:])}
	case dirFirst:
		candidates = []string{path.Join(dir, p), path.Clean(p)}
	default:
		candidates = []string{path.Clean(p)}
	}
	for _, c := range candidates {
		if exists(c) {
			c, _ = cleanRel(c)
			return c, frag, true, true
		}
	}
	if !strings.Contains(p, "/") {
		if hits := names[strings.ToLower(p)]; len(hits) == 1 {
			return hits[0], frag, true, true
		}
	}
	c, _ := cleanRel(candidates[0])
	return c, frag, true, false
}

// Extensions a zortex link can name besides resources ([./notes.txt]).
var textExts = map[string]bool{"txt": true, "md": true, "markdown": true, "csv": true, "html": true, "htm": true}

// fileLike reports whether a link definition names a file ("./scan.pdf",
// "./z/notes.zortex", "../folder") rather than a note: a resource or text
// extension, or a path relative to the note.
func (s *Server) fileLike(def string) bool {
	if strings.HasPrefix(def, "./") || strings.HasPrefix(def, "../") {
		return true
	}
	e := extOf(def)
	return s.resExts[e] || textExts[e]
}

// fileRefs reports every file reference on a line: zortex links to paths,
// markdown links and bare paths (strict: whether a missing target is a
// broken link, as for written links but not for bare paths in prose).
func (s *Server) fileRefs(spans []syntax.Span, fn func(target string, strict bool)) {
	syntax.Walk(spans, func(sp *syntax.Span) {
		switch sp.Type {
		case "link", "live_link":
			if s.fileLike(sp.Definition) {
				fn(sp.Definition, true)
			}
		case "markdown":
			fn(sp.URL, true)
		case "filepath":
			fn(strings.TrimRight(sp.Path, ".,;:!?"), false)
		}
	})
}

// collectFileLinks records the file references in a note (an archived
// note's missing files aren't broken links).
func (s *Server) collectFileLinks(doc *notes.Document, snap *snapshot, names map[string][]string) {
	archived := s.ix.IsArchived(doc.Rel)
	for lnum := range doc.Lines {
		lnum++
		if doc.InCode(lnum) {
			continue
		}
		s.fileRefs(doc.Spans(lnum), func(target string, strict bool) {
			s.addFileRef(snap, names, doc.Rel, true, lnum, doc.Lines[lnum-1], doc.NodeAt(lnum).Breadcrumb(" › "), target, strict && !archived, false)
		})
	}
}

// collectMarkdownLinks records the file references in a Markdown file.
func (s *Server) collectMarkdownLinks(rel string, snap *snapshot, names map[string][]string) {
	f, err := os.Open(s.ix.Path(rel))
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), maxLinkingFile)
	inFence := false
	for lnum := 1; sc.Scan(); lnum++ {
		line := sc.Text()
		if t := strings.TrimSpace(line); strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			inFence = !inFence
			continue
		}
		if inFence {
			continue
		}
		// Markdown images ![alt](path) are links here, not zortex live links
		md := strings.ReplaceAll(line, "![", " [")
		s.fileRefs(syntax.Inline(md, 0, len(md)), func(target string, strict bool) {
			s.addFileRef(snap, names, rel, false, lnum, line, "", target, strict, true)
		})
	}
}

func (s *Server) addFileRef(snap *snapshot, names map[string][]string, from string, fromNote bool, lnum int, line, breadcrumb, target string, strict, dirFirst bool) {
	rel, _, local, found := s.localRef(from, target, dirFirst, names)
	if !local {
		return
	}
	if !found {
		if strict {
			snap.broken = append(snap.broken, Broken{From: from, FromNote: fromNote, Lnum: lnum, Def: target, Err: "File not found"})
		}
		return
	}
	if rel == from {
		return
	}
	b := Backlink{From: from, FromNote: fromNote, Lnum: lnum, Line: line, Breadcrumb: breadcrumb, Def: target}
	switch {
	case s.isResource(rel):
		snap.fileBacklinks[rel] = append(snap.fileBacklinks[rel], b)
	case s.isNote(rel) && !fromNote:
		snap.backlinks[rel] = append(snap.backlinks[rel], b) // a Markdown file linking a note
	}
}

// =============================================================================
// Summaries
// =============================================================================

// unlinkedIn counts unlinked resources per folder (every ancestor folder,
// "" for the root); rebuild stores it as snapshot.unlinked.
func (snap *snapshot) unlinkedIn() map[string]int {
	out := map[string]int{}
	for _, r := range snap.resources {
		if len(snap.fileBacklinks[r.Rel]) > 0 {
			continue
		}
		dir := path.Dir(r.Rel)
		for {
			if dir == "." {
				dir = ""
			}
			out[dir]++
			if dir == "" {
				break
			}
			dir = path.Dir(dir)
		}
	}
	return out
}

// =============================================================================
// Pages
// =============================================================================

type resourceRow struct {
	resource
	Name  string
	Links int
}

type resourceFolder struct {
	Dir      string
	Total    int
	Unlinked int
	Rows     []resourceRow
}

// resourceFilter: GET /resources?show=unlinked|linked|all&kind=pdf&dir=z/books
type resourceFilter struct {
	Show, Kind, Dir string
}

func parseResourceFilter(r *http.Request) resourceFilter {
	q := r.URL.Query()
	f := resourceFilter{Show: q.Get("show"), Kind: q.Get("kind")}
	if f.Show != "linked" && f.Show != "all" {
		f.Show = "unlinked"
	}
	if dir, ok := cleanRel(q.Get("dir")); ok {
		f.Dir = dir
	}
	return f
}

// match reports whether a resource passes the folder and kind filters
// (Show is applied to rows only, so folder totals stay meaningful).
func (f resourceFilter) match(r resource) bool {
	if f.Kind != "" && r.Kind != f.Kind {
		return false
	}
	return f.Dir == "" || strings.HasPrefix(r.Rel, f.Dir+"/")
}

// URL of the page with one field changed.
func (s *Server) resourcesURL(f resourceFilter, key, value string) string {
	switch key {
	case "show":
		f.Show = value
	case "kind":
		f.Kind = value
	case "dir":
		f.Dir = value
	}
	q := url.Values{}
	if f.Show != "unlinked" {
		q.Set("show", f.Show)
	}
	if f.Kind != "" {
		q.Set("kind", f.Kind)
	}
	if f.Dir != "" {
		q.Set("dir", f.Dir)
	}
	u := s.url("/resources")
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	return u
}

const maxResourceRows = 2000

func (s *Server) handleResources(w http.ResponseWriter, r *http.Request) {
	snap := s.current()
	f := parseResourceFilter(r)
	byDir := map[string]*resourceFolder{}
	var dirs []string
	total, unlinked, shown := 0, 0, 0
	for _, res := range snap.resources {
		if !f.match(res) {
			continue
		}
		dir := path.Dir(res.Rel)
		if dir == "." {
			dir = ""
		}
		g := byDir[dir]
		if g == nil {
			g = &resourceFolder{Dir: dir}
			byDir[dir] = g
			dirs = append(dirs, dir)
		}
		links := len(snap.fileBacklinks[res.Rel])
		g.Total++
		total++
		if links == 0 {
			g.Unlinked++
			unlinked++
		}
		if (f.Show == "all" || (f.Show == "unlinked") == (links == 0)) && shown < maxResourceRows {
			g.Rows = append(g.Rows, resourceRow{resource: res, Name: path.Base(res.Rel), Links: links})
			shown++
		}
	}
	sort.Strings(dirs)
	folders := make([]resourceFolder, 0, len(dirs))
	for _, d := range dirs {
		folders = append(folders, *byDir[d])
	}
	type chip struct {
		Label, URL string
		On         bool
	}
	var shows, kinds []chip
	for _, v := range []string{"unlinked", "linked", "all"} {
		shows = append(shows, chip{v, s.resourcesURL(f, "show", v), f.Show == v})
	}
	kinds = append(kinds, chip{"any type", s.resourcesURL(f, "kind", ""), f.Kind == ""})
	for _, k := range resourceKinds {
		kinds = append(kinds, chip{k, s.resourcesURL(f, "kind", k), f.Kind == k})
	}
	folderURL := func(dir string) string { return s.resourcesURL(f, "dir", dir) }
	s.render(w, r, "resources", http.StatusOK, map[string]any{
		"Title":     "Resources",
		"Filter":    f,
		"Folders":   folders,
		"Shows":     shows,
		"Kinds":     kinds,
		"Total":     total,
		"Unlinked":  unlinked,
		"Shown":     shown,
		"Truncated": shown >= maxResourceRows,
		"FolderURL": folderURL,
		"AllDirs":   s.resourcesURL(f, "dir", ""),
	})
}

// apiResources: GET /api/resources?show=&kind=&dir= -> [{rel, kind, size, links, url}]
func (s *Server) apiResources(w http.ResponseWriter, r *http.Request) {
	snap := s.current()
	f := parseResourceFilter(r)
	type out struct {
		Rel   string `json:"rel"`
		Kind  string `json:"kind"`
		Size  int64  `json:"size"`
		Links int    `json:"links"`
		URL   string `json:"url"`
	}
	list := []out{}
	for _, res := range snap.resources {
		links := len(snap.fileBacklinks[res.Rel])
		if f.match(res) && (f.Show == "all" || (f.Show == "unlinked") == (links == 0)) {
			list = append(list, out{res.Rel, res.Kind, res.Size, links, s.fileURL(res.Rel)})
		}
	}
	writeJSON(w, http.StatusOK, list)
}
