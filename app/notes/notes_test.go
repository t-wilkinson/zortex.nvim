package notes

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScanMode(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "a.zortex"), "@@A\n# One\n")
	write(t, filepath.Join(dir, "z/b.zortex"), "@@B\n")
	write(t, filepath.Join(dir, ".z/hidden.zortex"), "@@Hidden\n")
	write(t, filepath.Join(dir, "z/scan.pdf"), "%PDF")
	write(t, filepath.Join(dir, "a.sync-conflict-20261015-143000-ABCDEFG.zortex"), "@@A\n")
	write(t, filepath.Join(dir, "z/b (Trey's conflicted copy 2026-10-15).zortex"), "@@B\n")
	ix, _ := Open(dir, ".zortex")

	if !ix.Scan() {
		t.Fatal("first scan should report a change")
	}
	if got := ix.All(); !reflect.DeepEqual(got, []string{"a.zortex", "z/b.zortex"}) {
		t.Fatalf("All = %v", got)
	}
	a := ix.Doc("a.zortex")
	if ix.Scan() {
		t.Error("nothing changed, Scan reported a change")
	}
	if ix.Doc("a.zortex") != a {
		t.Error("unchanged note was re-parsed")
	}

	// scanned mode doesn't see the disk until the next Scan
	write(t, filepath.Join(dir, "c.zortex"), "@@C\n")
	if ix.Doc("c.zortex") != nil || len(ix.All()) != 2 {
		t.Error("scanned mode read the disk")
	}
	if !ix.Scan() || ix.Doc("c.zortex") == nil {
		t.Error("new note not picked up")
	}

	// a change in content (and mtime) re-parses; a deletion drops
	later := time.Now().Add(2 * time.Second)
	write(t, filepath.Join(dir, "a.zortex"), "@@A2\n")
	os.Chtimes(filepath.Join(dir, "a.zortex"), later, later)
	os.Remove(filepath.Join(dir, "z/b.zortex"))
	if !ix.Scan() {
		t.Fatal("changes not reported")
	}
	if ix.Doc("a.zortex").Name() != "A2" || ix.Doc("z/b.zortex") != nil {
		t.Error("change or deletion not applied")
	}
}

func TestSpansMatchParse(t *testing.T) {
	lines := []string{"@@Note", "", "# Head [P/#x] **b**", "- [ ] task @p1 [Link]", "```", "[not]", "```", "**Bold**: x", "plain `c` $m$"}
	d := FromLines("n.zortex", lines)
	full := syntax.Parse(lines, true)
	for i, l := range full.Lines {
		got := d.Spans(i + 1)
		if len(got) == 0 && len(l.Inline) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, l.Inline) {
			t.Errorf("line %d: spans differ\n got %+v\nwant %+v", i+1, got, l.Inline)
		}
	}
	if !d.InCode(6) || d.InCode(4) {
		t.Error("InCode")
	}
	if d.Title() != "Note" || FromLines("z/x.zortex", []string{"text"}).Title() != "x" {
		t.Error("Title")
	}
}
