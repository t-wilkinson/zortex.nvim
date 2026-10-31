package notes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The Lua converter (lua/zortex/core/html.lua) wrote each
// tests/fixtures/html/x.zortex from x.html, read as z/html/x.html.
func TestHTMLLinesFixtures(t *testing.T) {
	pages, _ := filepath.Glob("../../tests/fixtures/html/*.html")
	if len(pages) == 0 {
		t.Fatal("no fixtures")
	}
	for _, page := range pages {
		src, err := os.ReadFile(page)
		if err != nil {
			t.Fatal(err)
		}
		want, err := os.ReadFile(strings.TrimSuffix(page, ".html") + ".zortex")
		if err != nil {
			t.Fatal(err)
		}
		got := strings.Join(HTMLLines(string(src), "z/html/"+filepath.Base(page)), "\n") + "\n"
		if got != string(want) {
			gl, wl := strings.Split(got, "\n"), strings.Split(string(want), "\n")
			for i := 0; i < len(gl) || i < len(wl); i++ {
				var g, w string
				if i < len(gl) {
					g = gl[i]
				}
				if i < len(wl) {
					w = wl[i]
				}
				if g != w {
					t.Errorf("%s line %d:\n got  %q\n want %q", filepath.Base(page), i+1, g, w)
					break
				}
			}
		}
	}
}
