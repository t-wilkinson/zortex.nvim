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

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// ArchiveTag marks archived notes (as do file names starting with "archive.").
const ArchiveTag = "Archive"

// Index is a notes folder. Documents are parsed on first use and cached
// until the file's modification time or size changes. Safe for concurrent use.
type Index struct {
	Root string // absolute folder path
	Ext  string // note extension, ".zortex"

	mu   sync.Mutex
	docs map[string]*cached
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
	all := ix.All()
	if includeArchived {
		return all
	}
	out := all[:0:0]
	for _, rel := range all {
		if !ix.IsArchived(rel) {
			out = append(out, rel)
		}
	}
	return out
}

// IsArchived reports whether a note is archived (archive.* name or @Archive tag).
func (ix *Index) IsArchived(rel string) bool {
	if strings.HasPrefix(filepath.Base(rel), "archive.") {
		return true
	}
	d := ix.Doc(rel)
	return d != nil && syntax.ListHas(d.Header().Tags, ArchiveTag)
}

// Path is the absolute path of a note.
func (ix *Index) Path(rel string) string {
	return filepath.Join(ix.Root, filepath.FromSlash(rel))
}

// Doc returns the parsed note, or nil when it can't be read.
func (ix *Index) Doc(rel string) *Document {
	path := ix.Path(rel)
	st, err := os.Stat(path)
	if err != nil {
		return nil
	}
	ix.mu.Lock()
	c := ix.docs[rel]
	ix.mu.Unlock()
	if c != nil && c.mtime == st.ModTime().UnixNano() && c.size == st.Size() {
		return c.doc
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	doc := FromLines(rel, syntax.SplitLines(string(data)))
	ix.mu.Lock()
	ix.docs[rel] = &cached{mtime: st.ModTime().UnixNano(), size: st.Size(), doc: doc}
	ix.mu.Unlock()
	return doc
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

// Document is a parsed note.
type Document struct {
	Rel     string
	Lines   []string
	AST     *syntax.AST
	Tree    *Node
	byStart map[int]*Node
}

// FromLines parses lines into a Document.
func FromLines(rel string, lines []string) *Document {
	ast := syntax.Parse(lines, false)
	d := &Document{Rel: rel, Lines: lines, AST: ast, Tree: buildTree(ast.Sections, len(lines)), byStart: map[int]*Node{}}
	d.Tree.Walk(func(n *Node) {
		if !n.IsRoot() {
			d.byStart[n.Start] = n
		}
	})
	return d
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
func (d *Document) Header() syntax.Header { return d.AST.Header }

// Name is the primary article name ("" when none).
func (d *Document) Name() string {
	if len(d.AST.Header.Names) > 0 {
		return d.AST.Header.Names[0]
	}
	return ""
}

// HasTag reports whether the header carries tag (ignoring case).
func (d *Document) HasTag(tag string) bool { return syntax.ListHas(d.AST.Header.Tags, tag) }

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
