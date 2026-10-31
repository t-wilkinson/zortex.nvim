package notes

import (
	"io/fs"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Documents: the Markdown files in a few folders (z/markdown and z/html
// unless Neovim's .z/syntax.json says otherwise) read as notes that links,
// search and hover cards reach, without being notes: Files and All leave
// them out, so projects, XP, tags and the broken-link scan never see them.
// As lua/zortex/core/documents.lua, a Markdown file reads line for line
// (MarkdownLines): its name from the front matter's title, else a first
// "# Title", else the file name; aliases and tags from the front matter,
// the file name as one more name.

// DefaultDocumentFolders is where documents are when nothing says otherwise.
var DefaultDocumentFolders = []string{"z/markdown", "z/html"}

// DocumentKind is "markdown" for a file in the documents' folders, "" for
// anything else.
func (ix *Index) DocumentKind(rel string) string {
	kind := docExtKind(rel)
	if kind == "" {
		return ""
	}
	ix.mu.Lock()
	folders := ix.docFolders
	ix.mu.Unlock()
	for _, f := range folders {
		if strings.HasPrefix(rel, f+"/") {
			return kind
		}
	}
	return ""
}

func docExtKind(rel string) string {
	switch strings.ToLower(strings.TrimPrefix(filepath.Ext(rel), ".")) {
	case "md", "markdown":
		return "markdown"
	}
	return ""
}

// SetDocumentFolders sets the folders (from the notes folder; nil: the
// defaults); reports whether they changed (the index forgets what it read).
func (ix *Index) SetDocumentFolders(folders []string) bool {
	if folders == nil {
		folders = DefaultDocumentFolders
	}
	var clean []string
	for _, f := range folders {
		f = strings.Trim(strings.TrimPrefix(filepath.ToSlash(f), "./"), "/")
		if f != "" && !strings.Contains("/"+f+"/", "/../") {
			clean = append(clean, f)
		}
	}
	ix.mu.Lock()
	same := len(clean) == len(ix.docFolders)
	for i := 0; same && i < len(clean); i++ {
		same = clean[i] == ix.docFolders[i]
	}
	ix.docFolders = clean
	ix.mu.Unlock()
	if !same {
		ix.Forget()
	}
	return !same
}

// DocumentFolders are the folders in use.
func (ix *Index) DocumentFolders() []string {
	ix.mu.Lock()
	defer ix.mu.Unlock()
	return append([]string(nil), ix.docFolders...)
}

// Documents lists the documents, top folders first, then by path.
func (ix *Index) Documents() []string {
	ix.mu.Lock()
	if ix.scanned {
		list := ix.docList
		ix.mu.Unlock()
		return list
	}
	ix.mu.Unlock()
	return ix.walkDocs()
}

func (ix *Index) walkDocs() []string {
	var out []string
	for _, f := range ix.DocumentFolders() {
		top := filepath.Join(ix.Root, filepath.FromSlash(f))
		_ = filepath.WalkDir(top, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			name := d.Name()
			if d.IsDir() {
				if path != top && strings.HasPrefix(name, ".") {
					return filepath.SkipDir
				}
				return nil
			}
			if !d.Type().IsRegular() || strings.HasPrefix(name, ".") || IsConflictCopy(name) || docExtKind(name) == "" {
				return nil
			}
			rel, _ := filepath.Rel(ix.Root, path)
			out = append(out, filepath.ToSlash(rel))
			return nil
		})
	}
	sortRels(out)
	return out
}

func sortRels(out []string) {
	sort.Slice(out, func(i, j int) bool {
		di, dj := strings.Count(out[i], "/"), strings.Count(out[j], "/")
		if di != dj {
			return di < dj
		}
		return out[i] < out[j]
	})
}

// asciiLower lowers ASCII letters only: the same bytes as the Lua's in any
// locale.
func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

func isHSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

func htrim(s string) string {
	i, j := 0, len(s)
	for i < j && isHSpace(s[i]) {
		i++
	}
	for j > i && isHSpace(s[j-1]) {
		j--
	}
	return s[i:j]
}

// docStem is a file's name without folder and last extension.
func docStem(rel string) string {
	name := rel
	if k := strings.LastIndexByte(name, '/'); k >= 0 {
		name = name[k+1:]
	}
	if k := strings.LastIndexByte(name, '.'); k > 0 && k < len(name)-1 {
		return name[:k]
	}
	return name
}

// =============================================================================
// Markdown
// =============================================================================

type mdEntry struct {
	key   string
	str   string
	list  []string
	isStr bool
}

func luaTrim(s string) string { return htrim(s) }

func mdUnquote(v string) string {
	v = luaTrim(v)
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
		return v[1 : len(v)-1]
	}
	return v
}

var (
	mdFMKey    = regexp.MustCompile("^([A-Za-z0-9_][A-Za-z0-9_\\-.]*):[ \t\n\r\f\v]*(.*)$")
	mdFMItem   = regexp.MustCompile("^[ \t\n\r\f\v]*-[ \t\n\r\f\v]+(.*)$")
	mdIndented = regexp.MustCompile("^[ \t\n\r\f\v]")
	mdDashItem = regexp.MustCompile("^-[ \t\n\r\f\v]")
	mdFence    = regexp.MustCompile("^[ \t\n\r\f\v]*([`~][`~][`~]+)")
	mdHeading  = regexp.MustCompile("^(#+)[ \t\n\r\f\v]+(.*)$")
	mdTrailHas = regexp.MustCompile("[ \t\n\r\f\v]+#+$")
	mdIDSuffix = regexp.MustCompile("[ \t\n\r\f\v]*\\{#[^}]*\\}$")
	mdSetext1  = regexp.MustCompile("^=+[ \t\n\r\f\v]*$")
	mdSetext2  = regexp.MustCompile("^--+[ \t\n\r\f\v]*$")
	mdNotPara  = regexp.MustCompile(`^([ \t\n\r\f\v]|[-*+>|]|[0-9]+[.)][ \t\n\r\f\v])`)
	mdLinkText = regexp.MustCompile(`\[([^\]]*)\]\([^)]*\)`)
	mdMarks    = regexp.MustCompile("[*_`]")
	mdTagSplit = regexp.MustCompile("[,\t\n\r\f\v ]+")
	mdTagSeps  = regexp.MustCompile("[/ \t\n\r\f\v]+")
)

func notBlank(s string) bool { return luaTrim(s) != "" }

// frontMatter reads "---" … "---"/"..." at the top: its entries and the
// line the body starts at (1-based; 1 without front matter). A small YAML
// subset, as features/markdown_import.front_matter.
func frontMatter(lines []string) ([]mdEntry, int, bool) {
	if len(lines) == 0 || luaTrim(lines[0]) != "---" {
		return nil, 1, false
	}
	close := -1
	for i := 1; i < len(lines); i++ {
		if t := luaTrim(lines[i]); t == "---" || t == "..." {
			close = i
			break
		}
	}
	if close < 0 {
		return nil, 1, false
	}
	var entries []mdEntry
	i := 1
	for i < close {
		m := mdFMKey.FindStringSubmatch(lines[i])
		if m == nil {
			i++
			continue
		}
		key, value := m[1], luaTrim(m[2])
		raw := []string{lines[i]}
		j := i + 1
		for j < close && (mdIndented.MatchString(lines[j]) || mdDashItem.MatchString(lines[j]) || !notBlank(lines[j])) {
			raw = append(raw, lines[j])
			j++
		}
		for len(raw) > 1 && !notBlank(raw[len(raw)-1]) {
			raw = raw[:len(raw)-1]
		}
		e := mdEntry{key: key}
		switch {
		case value == "" && len(raw) > 1:
			var list []string
			ok := true
			for _, r := range raw[1:] {
				im := mdFMItem.FindStringSubmatch(r)
				if im == nil {
					ok = false
					break
				}
				list = append(list, mdUnquote(luaTrim(im[1])))
			}
			if ok {
				e.list = list
			}
		case strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") && len(raw) == 1:
			for _, item := range strings.Split(value[1:len(value)-1], ",") {
				if item == "" {
					continue
				}
				if u := mdUnquote(item); u != "" {
					e.list = append(e.list, u)
				}
			}
			if e.list == nil {
				e.list = []string{}
			}
		case value != "" && len(raw) == 1 && value[0] != '|' && value[0] != '>':
			e.str, e.isStr = mdUnquote(value), true
		}
		entries = append(entries, e)
		i = j
	}
	return entries, close + 2, true
}

func mdTagWord(s string) string {
	s = strings.TrimPrefix(luaTrim(s), "#")
	s = mdTagSeps.ReplaceAllString(s, "-")
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ { // bytes, as Lua's [^%w_%-\128-\255]
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c >= 0x80 {
			b = append(b, c)
		}
	}
	return string(b)
}

func mdPlain(text string) string {
	return luaTrim(mdMarks.ReplaceAllString(mdLinkText.ReplaceAllString(text, "$1"), ""))
}

func mdHeadingText(text string) string {
	t := mdTrailHas.ReplaceAllString(luaTrim(text), "")
	return luaTrim(mdIDSuffix.ReplaceAllString(t, ""))
}

func mdFenceOf(line string) string {
	m := mdFence.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	f := m[1]
	if strings.Trim(f, "`") == "" || strings.Trim(f, "~") == "" {
		return f
	}
	return ""
}

// MarkdownLines is a Markdown file's lines as the notes read them, and its
// header (names and tags; the article on line 1): the same number of lines,
// front matter blank, setext headings as "#" ones, "## A ##" and
// "A {#id}" as "## A" (lua/zortex/core/documents.lua M.markdown).
func MarkdownLines(lines []string, rel string) ([]string, syntax.Header) {
	out := append([]string(nil), lines...)
	if len(out) > 0 {
		out[0] = strings.TrimPrefix(out[0], "\uFEFF")
	}
	title, hasTitle := "", false
	var aliases, tags []string
	fm, body, ok := frontMatter(out)
	if ok {
		for i := 0; i < body-1; i++ {
			out[i] = ""
		}
		for _, e := range fm {
			k := asciiLower(e.key)
			switch {
			case (k == "title" || k == "name") && e.isStr && e.str != "" && !hasTitle:
				title, hasTitle = e.str, true
			case k == "aliases" || k == "alias":
				if e.isStr {
					if e.str != "" {
						aliases = append(aliases, e.str)
					}
				} else {
					for _, a := range e.list {
						if a != "" {
							aliases = append(aliases, a)
						}
					}
				}
			case k == "tags" || k == "tag" || k == "keywords":
				list := e.list
				if e.isStr {
					list = nil
					for _, w := range mdTagSplit.Split(e.str, -1) {
						if w != "" {
							list = append(list, w)
						}
					}
				}
				for _, t := range list {
					if w := mdTagWord(t); w != "" {
						tags = append(tags, w)
					}
				}
			}
		}
	}

	fence := byte(0)
	first := true
	for i := body - 1; i < len(out); i++ {
		line := out[i]
		f := mdFenceOf(line)
		switch {
		case fence != 0:
			if f != "" && f[0] == fence {
				fence = 0
			}
		case f != "":
			fence = f[0]
			first = false
		case notBlank(line):
			if m := mdHeading.FindStringSubmatch(line); m != nil && len(m[1]) <= 6 {
				text := mdHeadingText(m[2])
				out[i] = m[1] + " " + text
				if first && len(m[1]) == 1 && !hasTitle {
					title, hasTitle = mdPlain(text), true
				}
			} else if i+1 < len(out) && !mdNotPara.MatchString(line) {
				level := 0
				if mdSetext1.MatchString(out[i+1]) {
					level = 1
				} else if mdSetext2.MatchString(out[i+1]) {
					level = 2
				}
				if level > 0 {
					out[i] = strings.Repeat("#", level) + " " + luaTrim(line)
					out[i+1] = ""
					if first && level == 1 && !hasTitle {
						title, hasTitle = mdPlain(line), true
					}
					i++
				}
			}
			first = false
		}
	}

	stem := docStem(rel)
	names := []string{stem}
	if title != "" {
		names[0] = title
	}
	seen := map[string]bool{asciiLower(names[0]): true}
	for _, a := range aliases {
		if !seen[asciiLower(a)] {
			seen[asciiLower(a)] = true
			names = append(names, a)
		}
	}
	if !seen[asciiLower(stem)] {
		names = append(names, stem)
	}
	if tags == nil {
		tags = []string{}
	}
	return out, syntax.Header{Names: names, Tags: tags, TagLines: []string{}, NameLnum: 1}
}

// fromDocument parses a document file's content into a Document (rel: the
// file's own path).
func fromDocument(rel, kind, content string) *Document {
	lines, header := MarkdownLines(syntax.SplitLines(content), rel)
	return fromLinesWith(rel, lines, &header)
}
