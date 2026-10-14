package web

import (
	"io"
	"log"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const talkNote = `@@Talk
@Example

Opening line.

# Why
## Structure @p1
- One
- Two

Notes:
- say this out loud
  - and this

## Steps @steps
- First
- Second
  - nested under second
- Third @step
Closing text.

# How
## Picture
![./images/pic.png]
![./images/missing.png]
![./clips/demo.mp4]
$x^2$ and
$$
\frac{1}{2}
$$
`

func newSlidesServer(t *testing.T, files map[string]string) *httptest.Server {
	t.Helper()
	dir := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	s, err := New(Config{Root: dir, Poll: -1, Logger: log.New(io.Discard, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return ts
}

var slideRe = regexp.MustCompile(`<section class="slide (\w+)" data-lnum="(\d+)" data-end="(\d+)" data-steps="(\d+)"`)

// slidesOf lists "kind lnum-end steps" for every slide of a deck page.
func slidesOf(body string) []string {
	var out []string
	for _, m := range slideRe.FindAllStringSubmatch(body, -1) {
		out = append(out, m[1]+" "+m[2]+"-"+m[3]+" "+m[4])
	}
	return out
}

func TestSlidesSplitAtHeadings(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{"talk.zortex": talkNote, "images/pic.png": "png"})
	body := expect(t, ts, "/n/talk.zortex?view=slides", 200, `<h1 class="deck-title">Talk</h1>`)
	got := strings.Join(slidesOf(body), ", ")
	want := "title 1-5 0, section 6-6 0, slide 7-14 0, slide 15-21 3, section 22-22 0, slide 23-30 0"
	if got != want {
		t.Fatalf("slides:\n got %s\nwant %s", got, want)
	}

	// @slides(1): # headings are the slides, ## stay inside them (and their
	// @steps is not the slide's)
	one := strings.Replace(talkNote, "@Example\n", "@Example\n@slides(1)\n", 1)
	ts1 := newSlidesServer(t, map[string]string{"talk.zortex": one})
	_, _, body1 := get(t, ts1, "/n/talk.zortex?view=slides")
	if got := strings.Join(slidesOf(body1), ", "); got != "title 1-6 0, slide 7-22 1, slide 23-31 0" {
		t.Fatalf("@slides(1): %s", got)
	}

	// a note without headings is one slide
	ts2 := newSlidesServer(t, map[string]string{"flat.zortex": "@@Flat\n\n- a\n- b\n"})
	_, _, body2 := get(t, ts2, "/n/flat.zortex?view=slides")
	if got := strings.Join(slidesOf(body2), ", "); got != "title 1-4 0" {
		t.Fatalf("flat: %s", got)
	}
}

func TestSlidesNotesStepsAndAttributes(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{"talk.zortex": talkNote})
	_, _, body := get(t, ts, "/n/talk.zortex?view=slides")
	deck := body[strings.Index(body, `id="deck"`):strings.Index(body, `id="presenter"`)]

	// speaker notes: out of the slide body, into its aside
	notes := regexp.MustCompile(`(?s)<aside class="notes">(.*?)</aside>`).FindAllStringSubmatch(deck, -1)
	if len(notes) != 1 || !strings.Contains(notes[0][1], "say this out loud") || !strings.Contains(notes[0][1], "and this") {
		t.Fatalf("notes: %q", notes)
	}
	if strings.Count(deck, "say this out loud") != 1 || strings.Contains(deck, `id="L11"`) {
		t.Error("the Notes: label or its lines are on the slide")
	}

	// @steps on the heading: each top-level item a step, nested lines with
	// their item; @step on a later item continues the count
	for _, want := range []string{
		`id="L16" data-step="1"`, `id="L17" data-step="2"`, `id="L18" style="--ind:2" data-step="2"`, `id="L19" data-step="3"`,
	} {
		if !strings.Contains(deck, want) {
			t.Errorf("missing %s", want)
		}
	}
	if strings.Contains(deck, `id="L20" data-step`) {
		t.Error("text after the items is a step")
	}

	// attributes are hidden on slides
	if strings.Contains(deck, `class="attr"`) || strings.Contains(deck, "@p1") {
		t.Error("attributes shown on a slide")
	}
	if strings.Contains(deck, `class="pin"`) == false {
		t.Error("slide headings lost their anchors")
	}
	expect(t, ts, "/n/talk.zortex", 200, `<span class="attr">@p1</span>`, `href="?view=slides"`)
}

func TestImageLinks(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{"talk.zortex": talkNote, "images/pic.png": "png", "clips/demo.mp4": "mp4"})
	body := expect(t, ts, "/n/talk.zortex", 200,
		`<img class="embed" src="/raw/images/pic.png" alt="pic.png" loading="lazy">`,
		`<a class="zl broken" title="File not found">./images/missing.png</a>`,
		`<video class="embed" src="/raw/clips/demo.mp4" controls preload="metadata" playsinline title="demo.mp4"></video>`,
		`<span class="math">x^2</span>`, `<pre class="math-block"`)
	if strings.Contains(body, `src="/raw/images/missing.png"`) {
		t.Error("missing image rendered")
	}
	// math.js loads KaTeX from the embedded files
	expect(t, ts, "/static/katex/katex.min.js", 200, "katex")
	expect(t, ts, "/static/katex/fonts/KaTeX_Main-Regular.woff2", 200)
}
