// Package tracker counts the time spent on a task while the home page's
// clocks run (a pomodoro work phase, the stopwatch, a timer) and hands it to
// a Write callback, which adds it to the task's @spent(...) in the notes.
//
// The task is either the current calendar entry ("calendar" mode, the
// default: it changes when the calendar moves on) or one picked by hand
// ("pinned"), or none ("off").
//
// Counting stops when no clock runs; the time counted so far is then written
// if it is at least MinWrite. Below that it waits: resuming the same task
// adds to it. When the task changes, the old task gets its time (or, under
// MinWrite, nothing) and the new one starts from zero.
package tracker

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// MinWrite is the least time that is written to a task.
const MinWrite = time.Minute

// Mode of choosing the task.
const (
	ModeCalendar = "calendar"
	ModePinned   = "pinned"
	ModeOff      = "off"
)

// Target is a line in a note: a task, or a calendar entry.
type Target struct {
	Rel  string `json:"rel"`
	Lnum int    `json:"lnum"`         // where it was last seen
	Line string `json:"line"`         // the line as last seen
	ID   string `json:"id,omitempty"` // its @id, the surest way to find it again
	Text string `json:"text"`         // for display (attributes removed)
	Key  string `json:"key"`          // identity: rel + @id, or rel + text
}

// Same reports whether two targets are the same line.
func Same(a, b *Target) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Key == b.Key
}

// State is the tracker as of Now.
type State struct {
	Mode    string    `json:"mode"`
	Task    *Target   `json:"task"`
	Pending int64     `json:"pending_ms"` // counted, not written yet (as of the last stop)
	Since   time.Time `json:"since"`      // counting since (zero: not counting)
	Bound   time.Time `json:"bound"`      // the running clocks end by then (zero: open-ended)
	Error   string    `json:"error,omitempty"`
	Now     time.Time `json:"now"`
	// Counted is Pending plus the running stretch, as of Now (ms).
	Counted int64 `json:"counted_ms"`
}

// Entry is one write, for the log.
type Entry struct {
	Task    Target    `json:"task"`
	Minutes int       `json:"minutes"`
	At      time.Time `json:"at"`
}

// Write adds minutes to a target's @spent and returns the target as it is
// now (its line changed).
type Write func(t Target, minutes int) (Target, error)

// Tracker keeps the state. Create it with Open.
type Tracker struct {
	path  string
	now   func() time.Time
	write Write
	// OnWrite is called (without the lock) after time was written.
	OnWrite func(Entry)

	mu sync.Mutex
	st State
}

// Open loads the state at path.
func Open(path string, write Write) (*Tracker, error) { return OpenAt(path, write, time.Now) }

// OpenAt is Open with another clock (tests).
func OpenAt(path string, write Write, now func() time.Time) (*Tracker, error) {
	t := &Tracker{path: path, write: write, now: now, st: State{Mode: ModeCalendar}}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(raw, &t.st); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if t.st.Mode == "" {
		t.st.Mode = ModeCalendar
	}
	return t, nil
}

// State returns the current state.
func (t *Tracker) State() State {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.snapshotLocked()
}

func (t *Tracker) snapshotLocked() State {
	st := t.st
	if st.Task != nil {
		c := *st.Task
		st.Task = &c
	}
	st.Now = t.now()
	st.Counted = st.Pending
	if !st.Since.IsZero() {
		st.Counted += t.runEnd(st.Now).Sub(st.Since).Milliseconds()
	}
	return st
}

// runEnd: when the running stretch ends if it ended now: now, or earlier
// when the clocks were due to stop before (a phase that ended while nobody
// looked).
func (t *Tracker) runEnd(now time.Time) time.Time {
	if !t.st.Bound.IsZero() && t.st.Bound.Before(now) {
		if t.st.Bound.Before(t.st.Since) {
			return t.st.Since
		}
		return t.st.Bound
	}
	return now
}

// Clocks is what the clocks are doing: whether any counts, and when the
// running ones end (zero: open-ended, e.g. the stopwatch).
type Clocks struct {
	Running bool
	Bound   time.Time
}

// Sync brings the tracker up to date: the clocks' state and, in calendar
// mode, the current calendar task (nil: none now).
func (t *Tracker) Sync(c Clocks, calendar *Target) (State, error) {
	t.mu.Lock()
	var entries []Entry
	var err error
	now := t.now()
	if t.st.Mode == ModeCalendar && !Same(t.st.Task, calendar) {
		entries, err = t.switchLocked(calendar, now)
	}
	switch {
	case c.Running && t.st.Since.IsZero():
		if t.st.Task != nil {
			t.st.Since, t.st.Bound = now, c.Bound
		}
	case c.Running:
		t.st.Bound = c.Bound
	case !t.st.Since.IsZero():
		t.st.Pending += t.runEnd(now).Sub(t.st.Since).Milliseconds()
		t.st.Since, t.st.Bound = time.Time{}, time.Time{}
		if time.Duration(t.st.Pending)*time.Millisecond >= MinWrite {
			e, werr := t.flushLocked()
			if werr != nil && err == nil {
				err = werr
			}
			entries = append(entries, e...)
		}
	}
	return t.finish(entries, err)
}

// Pin makes target the task (calendar mode ends).
func (t *Tracker) Pin(target Target) (State, error) {
	t.mu.Lock()
	t.st.Mode = ModePinned
	entries, err := t.switchLocked(&target, t.now())
	return t.finish(entries, err)
}

// Follow goes back to the calendar's task (current: nil when none now).
func (t *Tracker) Follow(current *Target) (State, error) {
	t.mu.Lock()
	t.st.Mode = ModeCalendar
	entries, err := t.switchLocked(current, t.now())
	return t.finish(entries, err)
}

// Off stops tracking (the current task gets its time).
func (t *Tracker) Off() (State, error) {
	t.mu.Lock()
	t.st.Mode = ModeOff
	entries, err := t.switchLocked(nil, t.now())
	return t.finish(entries, err)
}

// Flush writes what was counted so far (if at least MinWrite) without
// stopping (shutdown, or "save now").
func (t *Tracker) Flush() (State, error) {
	t.mu.Lock()
	now := t.now()
	if !t.st.Since.IsZero() {
		end := t.runEnd(now)
		t.st.Pending += end.Sub(t.st.Since).Milliseconds()
		t.st.Since = end
	}
	var entries []Entry
	var err error
	if time.Duration(t.st.Pending)*time.Millisecond >= MinWrite {
		entries, err = t.flushLocked()
	}
	return t.finish(entries, err)
}

// switchLocked closes the current task's account and starts next's.
func (t *Tracker) switchLocked(next *Target, now time.Time) ([]Entry, error) {
	if Same(t.st.Task, next) {
		if next != nil {
			c := *next
			t.st.Task = &c // same line, fresher position
		}
		return nil, nil
	}
	running := !t.st.Since.IsZero()
	if running {
		t.st.Pending += t.runEnd(now).Sub(t.st.Since).Milliseconds()
	}
	var entries []Entry
	var err error
	if t.st.Task != nil && time.Duration(t.st.Pending)*time.Millisecond >= MinWrite {
		entries, err = t.flushLocked()
	}
	t.st.Pending = 0
	t.st.Since, t.st.Bound = time.Time{}, time.Time{}
	if next != nil {
		c := *next
		t.st.Task = &c
		if running {
			t.st.Since = now
		}
	} else {
		t.st.Task = nil
	}
	return entries, err
}

// flushLocked writes Pending (rounded to minutes) to the task.
func (t *Tracker) flushLocked() ([]Entry, error) {
	if t.st.Task == nil || t.write == nil {
		t.st.Pending = 0
		return nil, nil
	}
	minutes := int((time.Duration(t.st.Pending)*time.Millisecond + 30*time.Second) / time.Minute)
	updated, err := t.write(*t.st.Task, minutes)
	if err != nil {
		t.st.Error = err.Error()
		return nil, err // keep Pending: written on the next try
	}
	t.st.Error = ""
	t.st.Pending = 0
	t.st.Task = &updated
	return []Entry{{Task: updated, Minutes: minutes, At: t.now()}}, nil
}

func (t *Tracker) finish(entries []Entry, err error) (State, error) {
	if serr := t.saveLocked(); serr != nil && err == nil {
		err = serr
	}
	st := t.snapshotLocked()
	onWrite := t.OnWrite
	t.mu.Unlock()
	if onWrite != nil {
		for _, e := range entries {
			onWrite(e)
		}
	}
	return st, err
}

func (t *Tracker) saveLocked() error {
	st := t.st
	st.Now, st.Counted = time.Time{}, 0
	raw, err := json.MarshalIndent(st, "", " ")
	if err != nil {
		return err
	}
	tmp := t.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, t.path)
}
