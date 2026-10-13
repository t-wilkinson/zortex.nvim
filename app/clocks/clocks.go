// Package clocks keeps the web app's timers, alarms and stopwatch: shared by
// every open page, persisted in the data directory, and announced through
// the Notify callback (ntfy) when a timer ends or an alarm rings, whether or
// not a page is open.
//
//   - Timers count down from a duration; they can be paused, resumed,
//     restarted and removed. A finished timer stays listed (done) until it
//     is dismissed or for 12 hours.
//   - Alarms ring at a time of day (server time), once or every day. A
//     one-off alarm turns itself off after ringing.
//   - The stopwatch counts up, with laps.
//
// A timer or alarm that came due while the server was down is announced when
// it starts again, if it is less than LateLimit late; otherwise it is settled
// silently.
package clocks

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	MaxTimers  = 20
	MaxAlarms  = 50
	MaxLaps    = 200
	MaxLabel   = 80
	MaxSeconds = 100 * 3600
	LateLimit  = 10 * time.Minute
	keepDone   = 12 * time.Hour
)

// Timer counts down.
type Timer struct {
	ID       string    `json:"id"`
	Label    string    `json:"label"`
	Duration int       `json:"duration"` // seconds
	Left     int       `json:"left"`     // seconds remaining (computed while running)
	Running  bool      `json:"running"`  //
	EndsAt   time.Time `json:"ends_at"`  // while running
	Done     bool      `json:"done"`     // ended (and announced)
	DoneAt   time.Time `json:"done_at"`  //
	Created  time.Time `json:"created"`  //
}

// Alarm rings at a time of day.
type Alarm struct {
	ID      string    `json:"id"`
	Label   string    `json:"label"`
	Time    string    `json:"time"`   // "HH:MM", server time
	Repeat  string    `json:"repeat"` // "once" | "daily"
	Enabled bool      `json:"enabled"`
	Next    time.Time `json:"next"`      // when it rings next (enabled)
	Rang    time.Time `json:"last_rang"` // when it last rang
}

// Stopwatch counts up.
type Stopwatch struct {
	Running   bool      `json:"running"`
	StartedAt time.Time `json:"started_at"` // start of the current run
	Base      int64     `json:"base_ms"`    // time accumulated before the current run
	Elapsed   int64     `json:"elapsed_ms"` // total at State.Now (computed)
	Laps      []int64   `json:"laps_ms"`    // total time at each lap
}

// State is everything, as of Now.
type State struct {
	Timers    []Timer   `json:"timers"`
	Alarms    []Alarm   `json:"alarms"`
	Stopwatch Stopwatch `json:"stopwatch"`
	Now       time.Time `json:"now"`
}

// Event is a timer that ended or an alarm that rang.
type Event struct {
	Kind  string // "timer" | "alarm"
	ID    string
	Label string
	At    time.Time // when it came due
	Timer *Timer
	Alarm *Alarm
}

// Message is the notification text for an event.
func Message(e Event) (title, body string, tags []string) {
	switch e.Kind {
	case "timer":
		title = "Timer done"
		if e.Label != "" {
			title = "Timer: " + e.Label
		}
		if e.Timer != nil {
			body = FormatDuration(e.Timer.Duration) + " timer ended at " + e.At.Format("15:04")
		}
		return title, body, []string{"timer", "hourglass"}
	default:
		title = "Alarm"
		if e.Label != "" {
			title = "Alarm: " + e.Label
		}
		body = e.At.Format("15:04")
		if e.Alarm != nil && e.Alarm.Repeat == "daily" {
			body += " (every day)"
		}
		return title, body, []string{"alarm", "alarm_clock"}
	}
}

// FormatDuration: 90 -> "1:30", 3600 -> "1:00:00".
func FormatDuration(sec int) string {
	h, m, s := sec/3600, sec%3600/60, sec%60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%d:%02d", m, s)
}

// Clocks holds the state. Create it with Open.
type Clocks struct {
	path   string
	now    func() time.Time
	Notify func(Event) // without the lock held, in a goroutine of its own

	mu    sync.Mutex
	st    State
	timer *time.Timer
	gen   int64
}

var (
	ErrNotFound = errors.New("no such timer or alarm")
	hhmm        = regexp.MustCompile(`^([01]?\d|2[0-3]):([0-5]\d)$`)
)

// Open loads the state persisted at path and resumes it.
func Open(path string) (*Clocks, error) { return OpenAt(path, time.Now) }

// OpenAt is Open with another clock (tests).
func OpenAt(path string, now func() time.Time) (*Clocks, error) {
	c := &Clocks{path: path, now: now}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(raw, &c.st); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	c.mu.Lock()
	events := c.settleLocked()
	c.scheduleLocked()
	notify := c.Notify
	c.mu.Unlock()
	c.announce(notify, events)
	return c, nil
}

// SetClock replaces time.Now (tests).
func (c *Clocks) SetClock(now func() time.Time) {
	c.mu.Lock()
	c.now = now
	c.scheduleLocked()
	c.mu.Unlock()
}

// State returns the current state.
func (c *Clocks) State() State {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshotLocked()
}

func (c *Clocks) snapshotLocked() State {
	now := c.now()
	st := State{Now: now, Timers: []Timer{}, Alarms: []Alarm{}}
	for _, t := range c.st.Timers {
		if t.Running {
			t.Left = int((t.EndsAt.Sub(now) + time.Second - 1) / time.Second)
			if t.Left < 0 {
				t.Left = 0
			}
		}
		st.Timers = append(st.Timers, t)
	}
	st.Alarms = append(st.Alarms, c.st.Alarms...)
	sort.SliceStable(st.Alarms, func(i, j int) bool { return st.Alarms[i].Time < st.Alarms[j].Time })
	sw := c.st.Stopwatch
	sw.Laps = append([]int64{}, sw.Laps...)
	sw.Elapsed = sw.Base
	if sw.Running {
		sw.Elapsed += now.Sub(sw.StartedAt).Milliseconds()
	}
	st.Stopwatch = sw
	return st
}

func newID() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func cleanLabel(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > MaxLabel {
		s = string(r[:MaxLabel])
	}
	return s
}

// nextAt: the first time after `after` that the clock shows hh:mm.
func nextAt(hm string, after time.Time) time.Time {
	m := hhmm.FindStringSubmatch(hm)
	var h, mi int
	fmt.Sscanf(m[1], "%d", &h)
	fmt.Sscanf(m[2], "%d", &mi)
	y, mo, d := after.Date()
	t := time.Date(y, mo, d, h, mi, 0, 0, after.Location())
	for !t.After(after) {
		d++
		t = time.Date(y, mo, d, h, mi, 0, 0, after.Location())
	}
	return t
}

// NormalizeTime turns "7:05" into "07:05"; ok is false for anything else.
func NormalizeTime(s string) (string, bool) {
	m := hhmm.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return "", false
	}
	if len(m[1]) == 1 {
		m[1] = "0" + m[1]
	}
	return m[1] + ":" + m[2], true
}

// =============================================================================
// Actions
// =============================================================================

// act runs fn under the lock, then saves, reschedules and announces whatever
// came due meanwhile.
func (c *Clocks) act(fn func(now time.Time) error) (State, error) {
	c.mu.Lock()
	events := c.settleLocked()
	err := fn(c.now())
	if err == nil {
		err = c.saveLocked()
	}
	c.scheduleLocked()
	st := c.snapshotLocked()
	notify := c.Notify
	c.mu.Unlock()
	c.announce(notify, events)
	return st, err
}

// AddTimer starts a timer of `seconds`.
func (c *Clocks) AddTimer(label string, seconds int) (State, error) {
	return c.act(func(now time.Time) error {
		if seconds < 1 || seconds > MaxSeconds {
			return fmt.Errorf("a timer runs between 1 second and %d hours", MaxSeconds/3600)
		}
		active := 0
		for _, t := range c.st.Timers {
			if !t.Done {
				active++
			}
		}
		if active >= MaxTimers {
			return fmt.Errorf("at most %d timers", MaxTimers)
		}
		c.st.Timers = append(c.st.Timers, Timer{
			ID: newID(), Label: cleanLabel(label), Duration: seconds, Left: seconds,
			Running: true, EndsAt: now.Add(time.Duration(seconds) * time.Second), Created: now,
		})
		return nil
	})
}

// TimerAction: pause | resume | restart | remove.
func (c *Clocks) TimerAction(id, action string) (State, error) {
	return c.act(func(now time.Time) error {
		i := -1
		for k := range c.st.Timers {
			if c.st.Timers[k].ID == id {
				i = k
			}
		}
		if i < 0 {
			return ErrNotFound
		}
		t := &c.st.Timers[i]
		switch action {
		case "pause":
			if t.Running {
				t.Left = int((t.EndsAt.Sub(now) + time.Second - 1) / time.Second)
				t.Running, t.EndsAt = false, time.Time{}
			}
		case "resume":
			if !t.Running && !t.Done && t.Left > 0 {
				t.Running, t.EndsAt = true, now.Add(time.Duration(t.Left)*time.Second)
			}
		case "restart":
			t.Running, t.Done, t.DoneAt = true, false, time.Time{}
			t.Left, t.EndsAt = t.Duration, now.Add(time.Duration(t.Duration)*time.Second)
		case "remove", "cancel", "dismiss":
			c.st.Timers = append(c.st.Timers[:i], c.st.Timers[i+1:]...)
		default:
			return fmt.Errorf("unknown timer action %q", action)
		}
		return nil
	})
}

// AddAlarm sets an alarm at hh:mm, repeat "once" or "daily".
func (c *Clocks) AddAlarm(label, at, repeat string) (State, error) {
	return c.act(func(now time.Time) error {
		hm, ok := NormalizeTime(at)
		if !ok {
			return fmt.Errorf("time %q: use HH:MM", at)
		}
		if repeat == "" {
			repeat = "once"
		}
		if repeat != "once" && repeat != "daily" {
			return fmt.Errorf("repeat %q: once or daily", repeat)
		}
		if len(c.st.Alarms) >= MaxAlarms {
			return fmt.Errorf("at most %d alarms", MaxAlarms)
		}
		c.st.Alarms = append(c.st.Alarms, Alarm{
			ID: newID(), Label: cleanLabel(label), Time: hm, Repeat: repeat, Enabled: true, Next: nextAt(hm, now),
		})
		return nil
	})
}

// AlarmAction: enable | disable | remove.
func (c *Clocks) AlarmAction(id, action string) (State, error) {
	return c.act(func(now time.Time) error {
		i := -1
		for k := range c.st.Alarms {
			if c.st.Alarms[k].ID == id {
				i = k
			}
		}
		if i < 0 {
			return ErrNotFound
		}
		a := &c.st.Alarms[i]
		switch action {
		case "enable":
			a.Enabled, a.Next = true, nextAt(a.Time, now)
		case "disable":
			a.Enabled, a.Next = false, time.Time{}
		case "remove", "delete":
			c.st.Alarms = append(c.st.Alarms[:i], c.st.Alarms[i+1:]...)
		default:
			return fmt.Errorf("unknown alarm action %q", action)
		}
		return nil
	})
}

// StopwatchAction: start | pause | toggle | lap | reset.
func (c *Clocks) StopwatchAction(action string) (State, error) {
	return c.act(func(now time.Time) error {
		sw := &c.st.Stopwatch
		total := sw.Base
		if sw.Running {
			total += now.Sub(sw.StartedAt).Milliseconds()
		}
		if action == "toggle" {
			action = "start"
			if sw.Running {
				action = "pause"
			}
		}
		switch action {
		case "start":
			if !sw.Running {
				sw.Running, sw.StartedAt = true, now
			}
		case "pause":
			if sw.Running {
				sw.Running, sw.StartedAt, sw.Base = false, time.Time{}, total
			}
		case "lap":
			if total > 0 && len(sw.Laps) < MaxLaps {
				sw.Laps = append(sw.Laps, total)
			}
		case "reset":
			*sw = Stopwatch{}
		default:
			return fmt.Errorf("unknown stopwatch action %q", action)
		}
		return nil
	})
}

// =============================================================================
// Firing
// =============================================================================

// settleLocked ends timers and rings alarms that are due, and drops old
// finished timers. It returns what to announce.
func (c *Clocks) settleLocked() []Event {
	now := c.now()
	var events []Event
	kept := c.st.Timers[:0]
	for _, t := range c.st.Timers {
		if t.Running && !t.EndsAt.After(now) {
			t.Running, t.Done, t.DoneAt, t.Left = false, true, t.EndsAt, 0
			t.EndsAt = time.Time{}
			tc := t
			events = append(events, Event{Kind: "timer", ID: t.ID, Label: t.Label, At: t.DoneAt, Timer: &tc})
		}
		if t.Done && now.Sub(t.DoneAt) > keepDone {
			continue
		}
		kept = append(kept, t)
	}
	c.st.Timers = kept
	for i := range c.st.Alarms {
		a := &c.st.Alarms[i]
		if !a.Enabled || a.Next.IsZero() || a.Next.After(now) {
			continue
		}
		due := a.Next
		a.Rang = due
		if a.Repeat == "daily" {
			a.Next = nextAt(a.Time, now)
		} else {
			a.Enabled, a.Next = false, time.Time{}
		}
		ac := *a
		events = append(events, Event{Kind: "alarm", ID: a.ID, Label: a.Label, At: due, Alarm: &ac})
	}
	if len(events) > 0 {
		_ = c.saveLocked()
	}
	return events
}

// scheduleLocked arms the timer for the next thing due.
func (c *Clocks) scheduleLocked() {
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
	var next time.Time
	for _, t := range c.st.Timers {
		if t.Running && (next.IsZero() || t.EndsAt.Before(next)) {
			next = t.EndsAt
		}
	}
	for _, a := range c.st.Alarms {
		if a.Enabled && !a.Next.IsZero() && (next.IsZero() || a.Next.Before(next)) {
			next = a.Next
		}
	}
	if next.IsZero() {
		return
	}
	d := next.Sub(c.now())
	if d < 0 {
		d = 0
	}
	// wake at least hourly: the wall clock can jump (suspend, NTP) under a
	// monotonic timer
	if d > time.Hour {
		d = time.Hour
	}
	c.gen++
	gen := c.gen
	c.timer = time.AfterFunc(d, func() { c.fire(gen) })
}

func (c *Clocks) fire(gen int64) {
	c.mu.Lock()
	if gen != c.gen {
		c.mu.Unlock()
		return
	}
	events := c.settleLocked()
	c.scheduleLocked()
	notify := c.Notify
	c.mu.Unlock()
	c.announce(notify, events)
}

// Tick settles what is due now and announces it synchronously (tests).
func (c *Clocks) Tick() []Event {
	c.mu.Lock()
	events := c.settleLocked()
	c.scheduleLocked()
	notify := c.Notify
	now := c.now()
	c.mu.Unlock()
	var out []Event
	for _, e := range events {
		if now.Sub(e.At) <= LateLimit {
			out = append(out, e)
			if notify != nil {
				notify(e)
			}
		}
	}
	return out
}

// announce sends events that are not too late.
func (c *Clocks) announce(notify func(Event), events []Event) {
	if notify == nil {
		return
	}
	now := c.State().Now
	for _, e := range events {
		if now.Sub(e.At) > LateLimit {
			continue
		}
		go notify(e)
	}
}

// Close stops the timer.
func (c *Clocks) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
	c.gen++
}

func (c *Clocks) saveLocked() error {
	st := c.st
	st.Now = time.Time{}
	raw, err := json.MarshalIndent(st, "", " ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}
