// Package notes reads a zortex notes folder: which files are notes, their
// headers, parsed documents and section trees. It ports core/notes,
// core/document and core/section from the plugin.
//
// Paths are "rel" paths: relative to the folder, "/"-separated.
package notes

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// ArchiveTag marks archived notes (as do file names starting with "archive.").
const ArchiveTag = "Archive"

// Index is a notes folder. Safe for concurrent use.
//
// It works in one of two modes. Live (after Open): All walks the folder and
// Doc re-reads a note when its modification time or size changed, so every
// call sees the disk. Scanned (after the first Scan): All and Doc serve what
// the last Scan saw without touching the disk, which is what a server that
// rescans on a timer wants; Scan reports whether anything changed.
type Index struct {
	Root string // absolute folder path
	Ext  string // note extension, ".zortex"

	mu      sync.Mutex
	docs    map[string]*cached
	scanned bool
	list    []string // scanned mode: every note, in All order
	catalog *Catalog // scanned mode: built on first use after a Scan
}

type cached struct {
	mtime int64
	size  int64
	doc   *Document
}

// Open returns the index of the notes folder at root.
func Open(root, ext string) (*Index, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if ext == "" {
		ext = ".zortex"
	}
	return &Index{Root: abs, Ext: ext, docs: map[string]*cached{}}, nil
}

// All lists every note, archived ones included: top-level notes first, then
// deeper ones, alphabetical by path. Hidden folders are skipped; symlinks are
// not followed (as in the plugin).
func (ix *Index) All() []string {
	ix.mu.Lock()
	if ix.scanned {
		list := ix.list
		ix.mu.Unlock()
		return list
	}
	ix.mu.Unlock()
	return ix.walk()
}

func (ix *Index) walk() []string {
	var out []string
	_ = filepath.WalkDir(ix.Root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if path != ix.Root && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() && strings.HasSuffix(d.Name(), ix.Ext) {
			rel, _ := filepath.Rel(ix.Root, path)
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Slice(out, func(i, j int) bool {
		di, dj := strings.Count(out[i], "/"), strings.Count(out[j], "/")
		if di != dj {
			return di < dj
		}
		return out[i] < out[j]
	})
	return out
}

// Files lists the notes, without archived ones unless includeArchived.
func (ix *Index) Files(includeArchived bool) []string {
	return ix.Catalog().Files(includeArchived)
}

// IsArchived reports whether a note is archived (archive.* name or @Archive tag).
func (ix *Index) IsArchived(rel string) bool {
	if strings.HasPrefix(filepath.Base(rel), "archive.") {
		return true
	}
	d := ix.Doc(rel)
	return d != nil && syntax.ListHas(d.Header().Tags, ArchiveTag)
}

// Catalog is the note list with lookups by header: which notes declare an
// article name or carry a tag, and which are archived. Lists keep All order.
type Catalog struct {
	all, active []string
	archived    map[string]bool
	byName      map[string][]string // lower-cased name -> notes
	byTag       map[string][]string // lower-cased tag -> notes
}

// Catalog returns the catalog of the notes: in scanned mode it is built once
// per Scan, in live mode on every call.
func (ix *Index) Catalog() *Catalog {
	ix.mu.Lock()
	if c := ix.catalog; c != nil && ix.scanned {
		ix.mu.Unlock()
		return c
	}
	ix.mu.Unlock()
	all := ix.All()
	c := &Catalog{archived: map[string]bool{}, byName: map[string][]string{}, byTag: map[string][]string{}}
	for _, rel := range all {
		d := ix.Doc(rel)
		if d == nil {
			continue
		}
		c.all = append(c.all, rel)
		h := d.Header()
		if strings.HasPrefix(filepath.Base(rel), "archive.") || syntax.ListHas(h.Tags, ArchiveTag) {
			c.archived[rel] = true
		} else {
			c.active = append(c.active, rel)
		}
		for _, n := range h.Names {
			k := syntax.Lower(n)
			if l := c.byName[k]; len(l) == 0 || l[len(l)-1] != rel {
				c.byName[k] = append(l, rel)
			}
		}
		for _, t := range h.Tags {
			k := syntax.Lower(t)
			if l := c.byTag[k]; len(l) == 0 || l[len(l)-1] != rel {
				c.byTag[k] = append(l, rel)
			}
		}
	}
	ix.mu.Lock()
	if ix.scanned {
		ix.catalog = c
	}
	ix.mu.Unlock()
	return c
}

// Files lists the notes, without archived ones unless includeArchived.
func (c *Catalog) Files(includeArchived bool) []string {
	if includeArchived {
		return c.all
	}
	return c.active
}

// IsArchived reports whether a note is archived.
func (c *Catalog) IsArchived(rel string) bool { return c.archived[rel] }

// WithName lists the notes declaring the article name (any @@ alias, ignoring case).
func (c *Catalog) WithName(name string) []string { return c.byName[syntax.Lower(name)] }

// WithTag lists the notes whose header carries the tag (ignoring case).
func (c *Catalog) WithTag(tag string) []string { return c.byTag[syntax.Lower(tag)] }

// Path is the absolute path of a note.
func (ix *Index) Path(rel string) string {
	return filepath.Join(ix.Root, filepath.FromSlash(rel))
}

// Doc returns the parsed note, or nil when it can't be read (or, in scanned
// mode, wasn't there at the last Scan).
func (ix *Index) Doc(rel string) *Document {
	ix.mu.Lock()
	c, scanned := ix.docs[rel], ix.scanned
	ix.mu.Unlock()
	if scanned {
		if c == nil {
			return nil
		}
		return c.doc
	}
	c = ix.load(rel, c)
	if c == nil {
		return nil
	}
	ix.mu.Lock()
	ix.docs[rel] = c
	ix.mu.Unlock()
	return c.doc
}

// load returns prev when the file is unchanged, otherwise the file parsed
// again (nil when it can't be read).
func (ix *Index) load(rel string, prev *cached) *cached {
	path := ix.Path(rel)
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return nil
	}
	if prev != nil && prev.mtime == st.ModTime().UnixNano() && prev.size == st.Size() {
		return prev
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	doc := FromLines(rel, syntax.SplitLines(string(data)))
	doc.ModTime = st.ModTime()
	return &cached{mtime: st.ModTime().UnixNano(), size: st.Size(), doc: doc}
}

// Scan reads the folder: new and changed notes are parsed, deleted ones are
// dropped, unchanged ones keep their parsed Document. From the first Scan on
// the index is in scanned mode (see Index). It reports whether any note was
// added, changed or removed.
func (ix *Index) Scan() bool {
	changed, _ := ix.ScanChanges()
	return changed
}

// ScanChanges is Scan, also naming the notes that were added, changed or
// removed (none on the first scan, which reports changed).
func (ix *Index) ScanChanges() (bool, []string) {
	list := ix.walk()
	ix.mu.Lock()
	prev, wasScanned := ix.docs, ix.scanned
	ix.mu.Unlock()

	docs := make(map[string]*cached, len(list))
	changed := !wasScanned
	var rels []string
	kept := list[:0:0]
	for _, rel := range list {
		old := prev[rel]
		c := ix.load(rel, old)
		if c == nil {
			continue
		}
		if c != old {
			changed = true
			if wasScanned {
				rels = append(rels, rel)
			}
		}
		docs[rel] = c
		kept = append(kept, rel)
	}
	if wasScanned {
		for rel := range prev {
			if docs[rel] == nil {
				changed = true
				rels = append(rels, rel)
			}
		}
	}
	ix.mu.Lock()
	ix.docs, ix.list, ix.scanned = docs, kept, true
	if changed {
		ix.catalog = nil
	}
	ix.mu.Unlock()
	return changed, rels
}

// =============================================================================
// Documents and section trees
// =============================================================================

// Node is a section: the article, a heading, bold heading or label. The root
// node (Type "root") holds the top-level sections.
type Node struct {
	Type     string
	Text     string   // display text, attributes stripped
	Names    []string // article: every @@ alias
	Level    int      // structural level (root -1, article 0, headings 1-6, bold 7, labels 8+)
	Start    int      // first line (1-based)
	End      int      // last line
	Parent   *Node
	Children []*Node
}

// IsRoot reports whether n is the synthetic root.
func (n *Node) IsRoot() bool { return n.Type == "root" }

// Path is the ancestors and n itself, root omitted, outermost first.
func (n *Node) Path() []*Node {
	var out []*Node
	for p := n; p != nil && !p.IsRoot(); p = p.Parent {
		out = append([]*Node{p}, out...)
	}
	return out
}

// Breadcrumb joins the texts of Path with sep.
func (n *Node) Breadcrumb(sep string) string {
	path := n.Path()
	texts := make([]string, len(path))
	for i, p := range path {
		texts[i] = p.Text
	}
	return strings.Join(texts, sep)
}

// Contains reports whether lnum is within the section.
func (n *Node) Contains(lnum int) bool { return lnum >= n.Start && lnum <= n.End }

// Walk visits the subtree in pre-order (n included).
func (n *Node) Walk(fn func(*Node)) {
	fn(n)
	for _, c := range n.Children {
		c.Walk(fn)
	}
}

// Document is a parsed note. It is immutable once built.
//
// It keeps the header, the section tree and, per line, only its kind and
// content columns: the full line descriptors (items, headings, fences, ...)
// are several times the size of the text, so Parse re-parses them for the
// few callers that need them (rendering).
type Document struct {
	Rel     string
	Lines   []string
	Tree    *Node
	ModTime time.Time // when read from disk (zero for FromLines)

	header  syntax.Header
	lines   []lineInfo
	byStart map[int]*Node
}

type lineInfo struct {
	kind     string
	from, to int32 // content columns for inline spans; from < 0: none
}

// FromLines parses lines into a Document.
func FromLines(rel string, lines []string) *Document {
	ast := syntax.Parse(lines, false)
	d := &Document{Rel: rel, Lines: lines, header: ast.Header, Tree: buildTree(ast.Sections, len(lines)), byStart: map[int]*Node{}}
	d.lines = make([]lineInfo, len(ast.Lines))
	for i, l := range ast.Lines {
		info := lineInfo{kind: l.Kind, from: -1}
		if l.ContentCol != nil {
			info.from, info.to = int32(*l.ContentCol), int32(len(lines[i]))
			if l.ContentEnd != nil {
				info.to = int32(*l.ContentEnd)
			}
		}
		d.lines[i] = info
	}
	d.Tree.Walk(func(n *Node) {
		if !n.IsRoot() {
			d.byStart[n.Start] = n
		}
	})
	return d
}

// Parse returns the full syntax of the note (parsed again on every call).
func (d *Document) Parse() *syntax.AST { return syntax.Parse(d.Lines, false) }

// Kind is the syntax kind of line lnum ("" out of range).
func (d *Document) Kind(lnum int) string {
	if lnum < 1 || lnum > len(d.lines) {
		return ""
	}
	return d.lines[lnum-1].kind
}

// buildTree assembles sections into a tree (core/section.build_tree_from_sections).
func buildTree(sections []*syntax.Section, lineCount int) *Node {
	root := &Node{Type: "root", Text: "Root", Level: -1, Start: 1, End: lineCount}
	stack := []*Node{root}
	for _, s := range sections {
		n := &Node{Type: s.Type, Text: s.Text, Names: s.Names, Level: s.Level, Start: s.Lnum, End: s.Lnum}
		for len(stack) > 1 && stack[len(stack)-1].Level >= s.Level {
			stack[len(stack)-1].End = s.Lnum - 1
			stack = stack[:len(stack)-1]
		}
		parent := stack[len(stack)-1]
		n.Parent = parent
		parent.Children = append(parent.Children, n)
		stack = append(stack, n)
	}
	for _, n := range stack[1:] {
		n.End = lineCount
	}
	return root
}

// Header is the note's @@names and @tags.
func (d *Document) Header() syntax.Header { return d.header }

// Name is the primary article name ("" when none).
func (d *Document) Name() string {
	if len(d.header.Names) > 0 {
		return d.header.Names[0]
	}
	return ""
}

// HasTag reports whether the header carries tag (ignoring case).
func (d *Document) HasTag(tag string) bool { return syntax.ListHas(d.header.Tags, tag) }

// NodeAt is the deepest section containing lnum (the root when none).
func (d *Document) NodeAt(lnum int) *Node {
	n := d.Tree
	for {
		var next *Node
		for _, c := range n.Children {
			if c.Contains(lnum) {
				next = c
				break
			}
		}
		if next == nil {
			return n
		}
		n = next
	}
}

// NodeStartingAt is the section whose header line is lnum, or nil.
func (d *Document) NodeStartingAt(lnum int) *Node { return d.byStart[lnum] }

// Spans are the inline spans of line lnum (links, emphasis, code, ...).
// They are parsed on each call, not kept: keeping them for every note
// costs more memory than re-parsing a line costs time.
func (d *Document) Spans(lnum int) []syntax.Span {
	if lnum < 1 || lnum > len(d.lines) {
		return nil
	}
	l := d.lines[lnum-1]
	if l.from < 0 {
		return nil
	}
	return syntax.Inline(d.Lines[lnum-1], int(l.from), int(l.to))
}

// InCode reports whether line lnum is inside (or opens/closes) a code or
// math block, where links are text.
func (d *Document) InCode(lnum int) bool {
	switch d.Kind(lnum) {
	case syntax.KindCode, syntax.KindFence, syntax.KindMath, syntax.KindMathFence:
		return true
	}
	return false
}

// Title is the article name, or the file name without the extension.
func (d *Document) Title() string {
	if name := d.Name(); name != "" {
		return name
	}
	base := filepath.Base(d.Rel)
	return strings.TrimSuffix(base, filepath.Ext(base))
}

// Sections lists every section in document order (pre-order, root excluded).
func (d *Document) Sections() []*Node {
	var out []*Node
	d.Tree.Walk(func(n *Node) {
		if !n.IsRoot() {
			out = append(out, n)
		}
	})
	return out
}
