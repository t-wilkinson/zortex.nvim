// Package feeds brings other calendars into the notes: zortex serve fetches
// each configured iCalendar feed (a Cozi family member's URL, a school's
// calendar, ...) on a timer and writes its events in the coming days into a
// note of their own, z/feeds/<name>.zortex, as ordinary calendar days:
//
//	@@Cozi
//	@CalendarFeed
//
//	Written by zortex serve from the "cozi" feed; edits here are replaced.
//
//	**2026-10-21:**
//	16:00 - 17:00 Soccer practice · Field 3 @n(no)
//	- Camping
//
// The note syncs to every device like any other, and Neovim and the web app
// read it with the calendar: the calendar view, the planner's "Coming up",
// the capacity line (its timed events are busy unless the feed says
// otherwise) and search. It is the feed's, not yours: each fetch replaces
// it, and only when something changed, so Syncthing sees few writes. The
// calendar note itself is never touched.
package feeds

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/ical"
)

// Feed is one calendar to fetch (an entry of the feeds file).
type Feed struct {
	// Name names the note (z/feeds/<name>.zortex): letters, digits, - and _
	Name string `json:"name"`
	// Title is the note's article name (default: Name)
	Title string `json:"title,omitempty"`
	// URL of the iCalendar feed (webcal:// is read as https://), or
	// URLFile: a file holding it (a feed's URL is a secret)
	URL     string `json:"url,omitempty"`
	URLFile string `json:"url_file,omitempty"`
	// Enabled: false stops fetching and removes the feed's note (default true)
	Enabled *bool `json:"enabled,omitempty"`
	// Notify: its timed events notify like your own (default false: they
	// are written with @n(no); the calendar they come from reminds you)
	Notify bool `json:"notify,omitempty"`
	// Busy: its timed events count as busy time in the planner's capacity
	// line (default true; false writes them with @free)
	Busy *bool `json:"busy,omitempty"`
	// Every: how often to fetch (default 15m, at least 5m)
	Every string `json:"every,omitempty"`
	// DaysBack / DaysAhead: the window written (default 7 and 60)
	DaysBack  int `json:"days_back,omitempty"`
	DaysAhead int `json:"days_ahead,omitempty"`
	// Color: a notifying feed's dot on the web app's month grid, on the
	// days it has events (a CSS color: "#e07a5f", "teal"; default
	// DefaultColor)
	Color string `json:"color,omitempty"`
}

// DefaultColor is a notifying feed's dot when it sets no color.
const DefaultColor = "#e8833a"

// colorRe: the CSS colors a feed may set: #rgb … #rrggbbaa, a name,
// rgb()/hsl() with numbers (nothing that could close the style attribute)
var colorRe = regexp.MustCompile(`^(#[0-9A-Fa-f]{3,8}|[A-Za-z]{3,30}|(rgb|rgba|hsl|hsla)\([0-9.,%/ ]+\))$`)

// DotColor: the feed's dot color.
func (f Feed) DotColor() string {
	if f.Color == "" {
		return DefaultColor
	}
	return f.Color
}

// File is the feeds file (-feeds, ZORTEX_FEEDS): { "feeds": [ ... ] }.
type File struct {
	Feeds []Feed `json:"feeds"`
}

var nameRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// Load reads and checks a feeds file.
func Load(path string) ([]Feed, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f File
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	seen := map[string]bool{}
	for i, fd := range f.Feeds {
		if !nameRe.MatchString(fd.Name) {
			return nil, fmt.Errorf("%s: feed %d: name %q: use letters, digits, - and _", path, i+1, fd.Name)
		}
		if seen[fd.Name] {
			return nil, fmt.Errorf("%s: two feeds named %q", path, fd.Name)
		}
		seen[fd.Name] = true
		if fd.URL == "" && fd.URLFile == "" && fd.On() {
			return nil, fmt.Errorf("%s: feed %q has no url or url_file", path, fd.Name)
		}
		if fd.Color != "" && !colorRe.MatchString(fd.Color) {
			return nil, fmt.Errorf("%s: feed %q: color %q: use #rrggbb, a CSS color name, rgb() or hsl()", path, fd.Name, fd.Color)
		}
		if _, err := fd.interval(); err != nil {
			return nil, fmt.Errorf("%s: feed %q: every: %w", path, fd.Name, err)
		}
	}
	return f.Feeds, nil
}

// On: the feed is fetched (Enabled unset or true).
func (f Feed) On() bool { return f.Enabled == nil || *f.Enabled }

func (f Feed) busy() bool { return f.Busy == nil || *f.Busy }

func (f Feed) interval() (time.Duration, error) {
	if f.Every == "" {
		return 15 * time.Minute, nil
	}
	d, err := time.ParseDuration(f.Every)
	if err != nil {
		return 0, err
	}
	return max(d, 5*time.Minute), nil
}

func (f Feed) title() string {
	if f.Title != "" {
		return f.Title
	}
	return f.Name
}

// Rel is the feed's note, relative to the notes folder.
func Rel(name, ext string) string { return "z/feeds/" + name + ext }

// Marker: the header tag of a feed's note (what readers look for)
const Marker = "@CalendarFeed"

// =============================================================================
// The note
// =============================================================================

// clean makes event text safe as a calendar line: one line, no link
// brackets, no @ that would read as a tag or attribute.
func clean(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	s = strings.NewReplacer("[", "(", "]", ")", "@", "＠").Replace(s)
	return strings.TrimLeft(s, "#*-> ")
}

// Note is the feed's note for the occurrences, days from..to (inclusive,
// "YYYY-MM-DD" in loc's calendar).
func Note(f Feed, occs []ical.Occurrence, from, to time.Time, loc *time.Location) []string {
	type line struct {
		allDay bool
		at     string
		text   string
	}
	days := map[string][]line{}
	first := dayStart(from, loc)
	last := dayStart(to, loc)
	tail := ""
	if !f.Notify {
		tail += " @n(no)"
	}
	if !f.busy() {
		tail += " @free"
	}
	for _, o := range occs {
		text := clean(o.Summary)
		if text == "" {
			text = "(no title)"
		}
		if place := clean(o.Location); place != "" {
			text += " · " + place
		}
		if o.AllDay {
			// every day it covers (End is the day after the last)
			d0, end := dayStart(o.Start, loc), dayStart(o.End, loc)
			if !end.After(d0) {
				end = d0.AddDate(0, 0, 1)
			}
			for d := d0; d.Before(end); d = d.AddDate(0, 0, 1) {
				if !d.Before(first) && !d.After(last) {
					key := d.Format("2006-01-02")
					days[key] = append(days[key], line{allDay: true, text: "- " + text})
				}
			}
			continue
		}
		start, end := o.Start.In(loc), o.End.In(loc)
		d := dayStart(start, loc)
		if d.Before(first) || d.After(last) {
			continue
		}
		var at string
		switch {
		case end.After(start) && dayStart(end, loc).Equal(d):
			at = start.Format("15:04") + " - " + end.Format("15:04")
		case end.After(start) && dayStart(end, loc).Equal(d.AddDate(0, 0, 1)) && end.Hour() == 0 && end.Minute() == 0:
			at = start.Format("15:04") + " - 23:59"
		default:
			at = start.Format("15:04")
			if end.After(start) {
				text += " (until " + end.Format("Mon 15:04") + ")"
			}
		}
		key := d.Format("2006-01-02")
		days[key] = append(days[key], line{at: start.Format("15:04"), text: at + " " + text + tail})
	}
	out := []string{
		"@@" + clean(f.title()),
		Marker,
		"",
		fmt.Sprintf("Written by zortex serve from the %q feed; edits here are replaced.", f.Name),
	}
	var keys []string
	for k := range days {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		ls := days[k]
		sort.SliceStable(ls, func(i, j int) bool {
			if ls[i].allDay != ls[j].allDay {
				return ls[i].allDay
			}
			return ls[i].at < ls[j].at
		})
		out = append(out, "", "**"+k+":**")
		for _, l := range ls {
			out = append(out, l.text)
		}
	}
	return out
}

func dayStart(t time.Time, loc *time.Location) time.Time {
	t = t.In(loc)
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, loc)
}

// write replaces path with lines when they differ; reports whether it wrote.
// Written atomically, through a temporary file Syncthing ignores.
func write(path string, lines []string) (bool, error) {
	data := []byte(strings.Join(lines, "\n") + "\n")
	if old, err := os.ReadFile(path); err == nil && bytes.Equal(old, data) {
		return false, nil
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return false, err
	}
	tmp, err := os.CreateTemp(dir, ".syncthing."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return false, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return false, err
	}
	return true, os.Rename(tmp.Name(), path)
}

// =============================================================================
// Fetching
// =============================================================================

// Runner fetches the feeds on their timers and writes their notes.
type Runner struct {
	Root    string // the notes folder
	Ext     string // ".zortex"
	Feeds   []Feed
	Log     *log.Logger
	Client  *http.Client
	Loc     *time.Location // default time.Local
	Now     func() time.Time
	OnWrite func() // after a note changed (the server rescans)

	cache map[string]*cached
}

type cached struct {
	etag, modified string
	body           []byte
}

func (r *Runner) init() {
	if r.Client == nil {
		r.Client = &http.Client{Timeout: 30 * time.Second}
	}
	if r.Loc == nil {
		r.Loc = time.Local
	}
	if r.Now == nil {
		r.Now = time.Now
	}
	if r.Log == nil {
		r.Log = log.Default()
	}
	if r.cache == nil {
		r.cache = map[string]*cached{}
	}
}

// Run fetches every feed now and then on its timer, until ctx ends. A feed
// that is off has its note removed.
func (r *Runner) Run(ctx context.Context) {
	r.init()
	for _, f := range r.Feeds {
		if !f.On() {
			r.remove(f)
			continue
		}
		every, _ := f.interval()
		go func(f Feed) {
			r.Update(ctx, f)
			t := time.NewTicker(every)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					r.Update(ctx, f)
				}
			}
		}(f)
	}
}

func (r *Runner) path(f Feed) string {
	return filepath.Join(r.Root, filepath.FromSlash(Rel(f.Name, r.Ext)))
}

// remove deletes a feed's note when it is one (it carries the marker).
func (r *Runner) remove(f Feed) {
	p := r.path(f)
	raw, err := os.ReadFile(p)
	if err != nil || !bytes.Contains(raw, []byte("\n"+Marker+"\n")) {
		return
	}
	if os.Remove(p) == nil {
		r.Log.Printf("feed %s: off, removed %s", f.Name, Rel(f.Name, r.Ext))
		if r.OnWrite != nil {
			r.OnWrite()
		}
	}
}

func (f Feed) url() (string, error) {
	u := f.URL
	if f.URLFile != "" {
		raw, err := os.ReadFile(f.URLFile)
		if err != nil {
			return "", err
		}
		u = strings.TrimSpace(string(raw))
	}
	if strings.HasPrefix(u, "webcal://") {
		u = "https://" + strings.TrimPrefix(u, "webcal://")
	}
	return u, nil
}

// Update fetches one feed (conditionally: only a changed feed is
// downloaded again) and rewrites its note. On a failed fetch the last body
// is used, so the window still moves with the days; with none, the note is
// left as it is.
func (r *Runner) Update(ctx context.Context, f Feed) error {
	r.init()
	c := r.cache[f.Name]
	if c == nil {
		c = &cached{}
		r.cache[f.Name] = c
	}
	if err := r.fetch(ctx, f, c); err != nil {
		r.Log.Printf("feed %s: %v", f.Name, err)
		if c.body == nil {
			return err
		}
	}
	now := r.Now().In(r.Loc)
	back, ahead := f.DaysBack, f.DaysAhead
	if back <= 0 {
		back = 7
	}
	if ahead <= 0 {
		ahead = 60
	}
	from := dayStart(now, r.Loc).AddDate(0, 0, -back)
	to := dayStart(now, r.Loc).AddDate(0, 0, ahead)
	events := ical.Parse(bytes.NewReader(c.body), r.Loc)
	occs := ical.Expand(events, from, to.AddDate(0, 0, 1))
	wrote, err := write(r.path(f), Note(f, occs, from, to, r.Loc))
	if err != nil {
		r.Log.Printf("feed %s: writing %s: %v", f.Name, Rel(f.Name, r.Ext), err)
		return err
	}
	if wrote {
		r.Log.Printf("feed %s: %d events in %s", f.Name, len(occs), Rel(f.Name, r.Ext))
		if r.OnWrite != nil {
			r.OnWrite()
		}
	}
	return nil
}

func (r *Runner) fetch(ctx context.Context, f Feed, c *cached) error {
	u, err := f.url()
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "zortex-serve (calendar feed)")
	req.Header.Set("Accept", "text/calendar, */*")
	if c.body != nil {
		if c.etag != "" {
			req.Header.Set("If-None-Match", c.etag)
		}
		if c.modified != "" {
			req.Header.Set("If-Modified-Since", c.modified)
		}
	}
	resp, err := r.Client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotModified && c.body != nil:
		return nil
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("fetch: %s", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}
	if !bytes.Contains(body, []byte("BEGIN:VCALENDAR")) {
		return fmt.Errorf("fetch: not an iCalendar feed")
	}
	c.body, c.etag, c.modified = body, resp.Header.Get("ETag"), resp.Header.Get("Last-Modified")
	return nil
}
