package feeds

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const feed = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
	"BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20261021T200000Z\r\nDTEND:20261021T210000Z\r\nSUMMARY:Soccer [practice] @home\r\nLOCATION:Field 3\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:2\r\nDTSTART;VALUE=DATE:20261024\r\nDTEND;VALUE=DATE:20261026\r\nSUMMARY:Camping\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:3\r\nDTSTART:20261019T130000Z\r\nDURATION:PT30M\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nSUMMARY:Piano\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:4\r\nDTSTART:20270101T130000Z\r\nSUMMARY:Too far ahead\r\nEND:VEVENT\r\n" +
	"END:VCALENDAR\r\n"

func runner(t *testing.T, url string) (*Runner, string) {
	t.Helper()
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skip("no zone database")
	}
	dir := t.TempDir()
	return &Runner{
		Root: dir, Ext: ".zortex", Loc: loc,
		Now: func() time.Time { return time.Date(2026, 10, 18, 12, 0, 0, 0, loc) },
	}, dir
}

func TestUpdateWritesTheNote(t *testing.T) {
	var hits, full atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Header.Get("If-None-Match") == `"v1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		full.Add(1)
		w.Header().Set("ETag", `"v1"`)
		w.Write([]byte(feed))
	}))
	defer ts.Close()
	r, dir := runner(t, ts.URL)
	writes := 0
	r.OnWrite = func() { writes++ }
	f := Feed{Name: "cozi", Title: "Cozi", URL: ts.URL}
	if err := r.Update(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "z", "feeds", "cozi.zortex"))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"@@Cozi",
		"@CalendarFeed",
		"",
		`Written by zortex serve from the "cozi" feed; edits here are replaced.`,
		"",
		"**2026-10-19:**",
		"09:00 - 09:30 Piano @n(no)",
		"",
		"**2026-10-21:**",
		"16:00 - 17:00 Soccer (practice) ＠home · Field 3 @n(no)",
		"",
		"**2026-10-24:**",
		"- Camping",
		"",
		"**2026-10-25:**",
		"- Camping",
		"",
		"**2026-10-26:**",
		"09:00 - 09:30 Piano @n(no)",
		"",
		"**2026-11-02:**",
		// 13:00Z repeats at 13:00 UTC: 09:00 EDT, then 08:00 EST from November 1
		"08:00 - 08:30 Piano @n(no)",
	}, "\n") + "\n"
	if got := string(raw); got != want {
		t.Fatalf("note:\n%s\nwant:\n%s", raw, want)
	}
	// again: not modified, same note, nothing written
	if err := r.Update(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	if writes != 1 || hits.Load() != 2 || full.Load() != 1 {
		t.Fatalf("writes %d, hits %d, full %d", writes, hits.Load(), full.Load())
	}
}

func TestOptionsAndFailures(t *testing.T) {
	up := true
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !up {
			http.Error(w, "down", http.StatusBadGateway)
			return
		}
		w.Write([]byte(feed))
	}))
	defer ts.Close()
	r, dir := runner(t, ts.URL)
	no := false
	// the URL from a file, as webcal://; notify on, not busy
	urlFile := filepath.Join(t.TempDir(), "url")
	os.WriteFile(urlFile, []byte(strings.Replace(ts.URL, "http://", "webcal://", 1)+"\n"), 0o600)
	f := Feed{Name: "kids", URLFile: urlFile, Notify: true, Busy: &no}
	// webcal:// becomes https://, which the test server doesn't speak: fails
	if err := r.Update(context.Background(), f); err == nil {
		t.Fatal("expected the https fetch to fail")
	}
	if _, err := os.Stat(filepath.Join(dir, "z", "feeds", "kids.zortex")); err == nil {
		t.Fatal("no note without a body")
	}
	f.URLFile, f.URL = "", ts.URL
	if err := r.Update(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "z", "feeds", "kids.zortex"))
	if !strings.Contains(string(raw), "16:00 - 17:00 Soccer (practice) ＠home · Field 3 @free\n") {
		t.Fatalf("notify on, not busy:\n%s", raw)
	}
	// the feed goes down: the last body still writes the note
	up = false
	if err := r.Update(context.Background(), f); err != nil {
		t.Fatalf("down, with a cached body: %v", err)
	}
	// off: Run removes its note
	f.Enabled = &no
	r.Feeds = []Feed{f}
	r.Run(context.Background())
	if _, err := os.Stat(filepath.Join(dir, "z", "feeds", "kids.zortex")); !os.IsNotExist(err) {
		t.Fatal("an off feed's note is removed")
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	os.WriteFile(good, []byte(`{"feeds":[{"name":"cozi","url":"https://x/y.ics","every":"30m","color":"#3a86ff"},{"name":"school","url_file":"/run/secrets/school","enabled":false},{"name":"club","url":"x","color":"hsl(150, 40%, 45%)"}]}`), 0o600)
	fs, err := Load(good)
	if err != nil || len(fs) != 3 || !fs[0].On() || fs[1].On() {
		t.Fatalf("%v %+v", err, fs)
	}
	if fs[0].DotColor() != "#3a86ff" || fs[1].DotColor() != DefaultColor {
		t.Fatalf("colors: %q %q", fs[0].DotColor(), fs[1].DotColor())
	}
	for _, bad := range []string{
		`{"feeds":[{"name":"a b","url":"x"}]}`,
		`{"feeds":[{"name":"a","url":"x"},{"name":"a","url":"y"}]}`,
		`{"feeds":[{"name":"a"}]}`,
		`{"feeds":[{"name":"a","url":"x","every":"soon"}]}`,
		`{"feeds":[{"name":"a","url":"x","color":"red\" onclick=\"x"}]}`,
		`{"feeds":[{"name":"a","url":"x","color":"url(x)"}]}`,
	} {
		p := filepath.Join(dir, "bad.json")
		os.WriteFile(p, []byte(bad), 0o600)
		if _, err := Load(p); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}
