package web

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Markdown documents (notes/documents.go): links to their headings land on
// their file pages, which say what links them; the search, hover cards and
// /broken see them; .z/syntax.json moves them.
func TestDocuments(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	os.WriteFile(filepath.Join(dir, "doc-links.zortex"), []byte(strings.Join([]string{
		"@@Doc links",
		"",
		"- [Rust Ownership/#Borrowing]",
		"- [Tide Tables/#King tides]",
		"- [Ownership]",
	}, "\n")+"\n"), 0o644)
	s.Refresh()

	expect(t, ts, "/n/doc-links.zortex", 200,
		`href="/f/z/markdown/rust-ownership.md#L12"`,
		`href="/f/z/markdown/rust-ownership.md#L1"`)
	if n := strings.Count(expect(t, ts, "/broken", 200, "King tides"), "z/markdown/rust-ownership.md"); n != 0 {
		t.Errorf("a document's own text on /broken (%d)", n)
	}

	// the Markdown file: rendered as before, with what links it
	expect(t, ts, "/f/z/markdown/rust-ownership.md", 200, `id="L12"`, "Linked from", `href="/n/doc-links.zortex#L3"`)
	// hover cards
	if code, card := getJSON(t, ts, "/api/hover?rel=z/markdown/rust-ownership.md&lnum=12"); code != 200 || !strings.Contains(card["section"].(string), "Borrowing") {
		t.Errorf("hover: %d %v", code, card)
	}
	os.WriteFile(filepath.Join(dir, "README.md"), []byte("# Read me\n"), 0o644)
	s.Refresh()
	if code, _ := getJSON(t, ts, "/api/hover?rel=README.md&lnum=0"); code != 404 {
		t.Errorf("hover on a Markdown file outside the folders: %d", code)
	}

	// search
	expect(t, ts, "/search?q=spring+tides", 200, `href="/f/z/markdown/tide-tables.md#L5"`)
	expect(t, ts, "/search?q=outlive&mode=text", 200, `z/markdown/rust-ownership.md`)

	// not notes: no tags, projects or note list
	expect(t, ts, "/tags", 200)
	if strings.Contains(expect(t, ts, "/tags", 200), "@rust") {
		t.Error("a document's tags among the notes'")
	}

	// other folders, from Neovim's .z/syntax.json
	os.MkdirAll(filepath.Join(dir, ".z"), 0o755)
	os.WriteFile(filepath.Join(dir, ".z", "syntax.json"), []byte(`{"version":1,"documents":["z/markdown"]}`), 0o644)
	s.Refresh()
	expect(t, ts, "/n/doc-links.zortex", 200, `href="/f/z/markdown/rust-ownership.md#L12"`)
	os.WriteFile(filepath.Join(dir, ".z", "syntax.json"), []byte(`{"version":1,"documents":[]}`), 0o644)
	s.Refresh()
	expect(t, ts, "/broken", 200, "Rust Ownership/#Borrowing")
}
