// Package pomodoro is the pomodoro clock shared by Neovim and the web app.
// The server owns the clock: both clients send actions (start, pause, skip,
// ...) and read the same state, and phase changes are announced through a
// Notify callback (ntfy) even when no client is open.
//
// A cycle is LongBreakAfter work sessions, each followed by a short break,
// except the last, which is followed by a long break. After the long break a
// new cycle begins: that work session is announced as a restart.
package pomodoro

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Phases
const (
	Idle       = "idle"
	Work       = "work"
	ShortBreak = "short_break"
	LongBreak  = "long_break"
)

// Event kinds passed to Notify. Each has its own ntfy tag, so a subscriber
// script can play a different sound for each (see contrib/ntfy/notify.sh).
const (
	EventWorkStart  = "work_start"  // a work session began
	EventBreakStart = "break_start" // a short or long break began
	EventRestart    = "restart"     // a new cycle began (after a long break, or restarted by hand)
	EventWorkEnd    = "work_end"    // work ended; the break waits to be started
	EventBreakEnd   = "break_end"   // a break ended; work waits to be started
	EventStop       = "stop"        // stopped by hand
)

// Settings of the clock. Durations are in minutes.
type Settings struct {
	Work           int  `json:"work"`
	ShortBreak     int  `json:"short_break"`
	LongBreak      int  `json:"long_break"`
	LongBreakAfter int  `json:"long_break_after"`
	AutoStartBreak bool `json:"auto_start_break"`
	AutoStartWork  bool `json:"auto_start_work"`
}

// DefaultSettings: 25/5/15, a long break after 4 sessions.
var DefaultSettings = Settings{Work: 25, ShortBreak: 5, LongBreak: 15, LongBreakAfter: 4, AutoStartBreak: true, AutoStartWork: false}

func (s Settings) valid() error {
	switch {
	case s.Work < 1 || s.Work > 600:
		return errors.New("work must be 1-600 minutes")
	case s.ShortBreak < 1 || s.ShortBreak > 600:
		return errors.New("short_break must be 1-600 minutes")
	case s.LongBreak < 1 || s.LongBreak > 600:
		return errors.New("long_break must be 1-600 minutes")
	case s.LongBreakAfter < 1 || s.LongBreakAfter > 20:
		return errors.New("long_break_after must be 1-20")
	}
	return nil
}

func (s Settings) duration(phase string) time.Duration {
	switch phase {
	case Work:
		return time.Duration(s.Work) * time.Minute
	case ShortBreak:
		return time.Duration(s.ShortBreak) * time.Minute
	case LongBreak:
		return time.Duration(s.LongBreak) * time.Minute
	}
	return 0
}

// State is the clock as clients see it.
//
//	idle                       Phase == Idle
//	running                    Running, EndsAt set
//	paused                     !Running, Started, Remaining left in the phase
//	waiting to start a phase   !Running, !Started (auto-start off): Phase is the next phase
type State struct {
	Phase     string    `json:"phase"`
	Running   bool      `json:"running"`
	Started   bool      `json:"started"`   // the phase has begun (false: waiting to start it)
	EndsAt    time.Time `json:"ends_at"`   // running: when the phase ends
	Remaining int       `json:"remaining"` // seconds left (computed when running)
	Duration  int       `json:"duration"`  // seconds in the whole phase
	Session   int       `json:"session"`   // work session within the cycle, 1-based (0: none yet)
	Completed int       `json:"completed"` // work sessions finished in this cycle
	Today     int       `json:"today"`     // work sessions finished today
	Day       string    `json:"day"`       // the day Today counts (local, YYYY-MM-DD)
	Settings  Settings  `json:"settings"`
	Version   int64     `json:"version"` // bumped on every change
	UpdatedAt time.Time `json:"updated_at"`
	LastEvent string    `json:"last_event,omitempty"` // kind of the last announced event
	Now       time.Time `json:"now"`                  // server time (lets clients correct their clock)
}

// Event is a phase change, passed to Clock.Notify.
type Event struct {
	Kind  string
	State State
}

// Clock is the pomodoro clock. Create it with Open.
type Clock struct {
	path   string
	now    func() time.Time
	Notify func(Event) // called without the lock held, in a goroutine of its own

	mu    sync.Mutex
	st    State
	timer *time.Timer
}

// Open loads the clock persisted at path (a JSON file) and resumes it. A
// phase that ended while the server was down is advanced past silently.
func Open(path string) (*Clock, error) {
	c := &Clock{path: path, now: time.Now}
	c.st = State{Phase: Idle, Settings: DefaultSettings}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(raw, &c.st); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if c.st.Settings.valid() != nil {
			c.st.Settings = DefaultSettings
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	c.mu.Lock()
	c.catchUpLocked()
	c.scheduleLocked()
	c.mu.Unlock()
	return c, nil
}

// SetClock replaces time.Now (tests). Call before any action.
func (c *Clock) SetClock(now func() time.Time) {
	c.mu.Lock()
	c.now = now
	c.mu.Unlock()
}

// State returns the current state.
func (c *Clock) State() State {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshotLocked()
}

func (c *Clock) snapshotLocked() State {
	st := c.st
	now := c.now()
	st.Now = now
	if st.Running {
		st.Remaining = int(st.EndsAt.Sub(now).Round(time.Second) / time.Second)
		if st.Remaining < 0 {
			st.Remaining = 0
		}
	}
	if st.Day != now.Format("2006-01-02") {
		st.Today = 0
	}
	return st
}

// Actions

// Start: idle -> a work session; waiting -> begin the waiting phase; paused -> resume.
func (c *Clock) Start() (State, error) {
	return c.act(func(now time.Time) (string, error) {
		st := &c.st
		switch {
		case st.Phase == Idle:
			st.Completed = 0
			return c.beginLocked(Work, now), nil
		case st.Running:
			return "", nil
		case !st.Started:
			return c.beginLocked(st.Phase, now), nil
		default: // paused
			st.Running, st.EndsAt = true, now.Add(time.Duration(st.Remaining)*time.Second)
			return "", nil
		}
	})
}

// Pause a running phase.
func (c *Clock) Pause() (State, error) {
	return c.act(func(now time.Time) (string, error) {
		st := &c.st
		if !st.Running {
			return "", errors.New("not running")
		}
		st.Remaining = int(st.EndsAt.Sub(now).Round(time.Second) / time.Second)
		if st.Remaining < 1 {
			st.Remaining = 1
		}
		st.Running, st.EndsAt = false, time.Time{}
		return "", nil
	})
}

// Resume a paused phase (same as Start when paused).
func (c *Clock) Resume() (State, error) {
	c.mu.Lock()
	paused := c.st.Phase != Idle && !c.st.Running && c.st.Started
	c.mu.Unlock()
	if !paused {
		return c.State(), errors.New("not paused")
	}
	return c.Start()
}

// Toggle: start, pause or resume, whichever applies.
func (c *Clock) Toggle() (State, error) {
	c.mu.Lock()
	running := c.st.Running
	c.mu.Unlock()
	if running {
		return c.Pause()
	}
	return c.Start()
}

// Skip ends the current phase now (as if its time ran out).
func (c *Clock) Skip() (State, error) {
	return c.act(func(now time.Time) (string, error) {
		if c.st.Phase == Idle {
			return "", errors.New("not running")
		}
		if !c.st.Started {
			// waiting for a break: skip it and get back to work
			if c.st.Phase == Work {
				return "", errors.New("work is waiting to be started")
			}
			return c.beginLocked(Work, now), nil
		}
		return c.finishLocked(now), nil
	})
}

// Stop: back to idle. The next Start begins a new cycle.
func (c *Clock) Stop() (State, error) {
	return c.act(func(now time.Time) (string, error) {
		if c.st.Phase == Idle {
			return "", nil
		}
		c.st.Phase, c.st.Running, c.st.Started, c.st.EndsAt, c.st.Remaining, c.st.Duration, c.st.Session = Idle, false, false, time.Time{}, 0, 0, 0
		return EventStop, nil
	})
}

// Restart begins a new cycle with a fresh work session.
func (c *Clock) Restart() (State, error) {
	return c.act(func(now time.Time) (string, error) {
		c.st.Completed = 0
		c.beginLocked(Work, now)
		return EventRestart, nil
	})
}

// Update changes the settings. A running phase keeps its end time; a phase
// that is waiting or paused takes the new duration when it hasn't begun.
func (c *Clock) Update(s Settings) (State, error) {
	if err := s.valid(); err != nil {
		return c.State(), err
	}
	return c.act(func(now time.Time) (string, error) {
		c.st.Settings = s
		if c.st.Phase != Idle && !c.st.Started {
			c.st.Duration = int(s.duration(c.st.Phase) / time.Second)
			c.st.Remaining = c.st.Duration
		}
		return "", nil
	})
}

// act runs fn under the lock, saves, reschedules and announces fn's event.
func (c *Clock) act(fn func(now time.Time) (string, error)) (State, error) {
	c.mu.Lock()
	expired, expiredState := c.expireLocked() // a phase that just ran out ends first
	now := c.now()
	notify := c.Notify
	event, err := fn(now)
	if err != nil {
		st := c.snapshotLocked()
		c.mu.Unlock()
		if expired != "" && notify != nil {
			go notify(Event{Kind: expired, State: expiredState})
		}
		return st, err
	}
	c.touchLocked(now, event)
	serr := c.saveLocked()
	c.scheduleLocked()
	st := c.snapshotLocked()
	c.mu.Unlock()
	if notify != nil {
		go func() {
			if expired != "" {
				notify(Event{Kind: expired, State: expiredState})
			}
			if event != "" {
				notify(Event{Kind: event, State: st})
			}
		}()
	}
	return st, serr
}

func (c *Clock) touchLocked(now time.Time, event string) {
	c.st.Version++
	c.st.UpdatedAt = now
	if event != "" {
		c.st.LastEvent = event
	}
}

// next phase after `phase` given the cycle count.
func (c *Clock) next(phase string) string {
	if phase != Work {
		return Work
	}
	if c.st.Completed >= c.st.Settings.LongBreakAfter {
		return LongBreak
	}
	return ShortBreak
}

// beginLocked starts `phase` now and returns the event announcing it.
func (c *Clock) beginLocked(phase string, now time.Time) string {
	st := &c.st
	event := EventBreakStart
	if phase == Work {
		event = EventWorkStart
		if st.Completed >= st.Settings.LongBreakAfter {
			st.Completed = 0 // a new cycle
		}
		if st.Completed == 0 && st.Session > 0 {
			event = EventRestart // back to work after a long break
		}
		st.Session = st.Completed + 1
	}
	d := st.Settings.duration(phase)
	st.Phase, st.Running, st.Started = phase, true, true
	st.Duration, st.Remaining = int(d/time.Second), int(d/time.Second)
	st.EndsAt = now.Add(d)
	return event
}

// finishLocked ends the current phase at `at` and moves on; returns the event.
func (c *Clock) finishLocked(at time.Time) string {
	st := &c.st
	ended := st.Phase
	if ended == Work {
		st.Completed++
		day := at.Format("2006-01-02")
		if st.Day != day {
			st.Day, st.Today = day, 0
		}
		st.Today++
	}
	next := c.next(ended)
	auto := (ended == Work && st.Settings.AutoStartBreak) || (ended != Work && st.Settings.AutoStartWork)
	if auto {
		return c.beginLocked(next, at)
	}
	d := st.Settings.duration(next)
	st.Phase, st.Running, st.Started, st.EndsAt = next, false, false, time.Time{}
	st.Duration, st.Remaining = int(d/time.Second), int(d/time.Second)
	if ended == Work {
		return EventWorkEnd
	}
	return EventBreakEnd
}

// catchUpLocked advances phases that ended while nobody was looking (server
// down): silently, using each phase's own end time.
func (c *Clock) catchUpLocked() {
	for i := 0; i < 100 && c.st.Running && !c.st.EndsAt.After(c.now()); i++ {
		c.finishLocked(c.st.EndsAt)
		c.touchLocked(c.now(), "")
	}
}

// scheduleLocked arms the timer for the end of the running phase.
func (c *Clock) scheduleLocked() {
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
	if !c.st.Running {
		return
	}
	d := c.st.EndsAt.Sub(c.now())
	if d < 0 {
		d = 0
	}
	version := c.st.Version
	c.timer = time.AfterFunc(d, func() { c.fire(version) })
}

// expireLocked ends the running phase if its time is up: saves, reschedules
// and returns the event to announce (and the state after it).
func (c *Clock) expireLocked() (string, State) {
	if !c.st.Running || c.st.EndsAt.After(c.now()) {
		return "", State{}
	}
	event := c.finishLocked(c.st.EndsAt)
	c.touchLocked(c.now(), event)
	_ = c.saveLocked()
	c.scheduleLocked()
	return event, c.snapshotLocked()
}

// fire ends the phase the timer was armed for (unless the state changed).
func (c *Clock) fire(version int64) {
	c.mu.Lock()
	if c.st.Version != version {
		c.mu.Unlock()
		return
	}
	if c.st.Running && c.st.EndsAt.After(c.now()) { // early wakeup
		c.scheduleLocked()
		c.mu.Unlock()
		return
	}
	event, st := c.expireLocked()
	notify := c.Notify
	c.mu.Unlock()
	if event != "" && notify != nil {
		go notify(Event{Kind: event, State: st})
	}
}

// Tick ends the running phase if its time is up and announces it
// synchronously (tests, and a safety net next to the timer). Returns the
// event, if any.
func (c *Clock) Tick() string {
	c.mu.Lock()
	event, st := c.expireLocked()
	notify := c.Notify
	c.mu.Unlock()
	if event != "" && notify != nil {
		notify(Event{Kind: event, State: st})
	}
	return event
}

// Close stops the timer.
func (c *Clock) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
}

func (c *Clock) saveLocked() error {
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

// PhaseName is a human name for a phase.
func PhaseName(phase string) string {
	switch phase {
	case Work:
		return "Work"
	case ShortBreak:
		return "Short break"
	case LongBreak:
		return "Long break"
	}
	return "Idle"
}

// Message is the notification text for an event: title, body and ntfy tags.
// Tags carry the event kind ("pomodoro-work-start", ...) for subscriber
// scripts, plus an emoji shortcode for the phone.
func Message(e Event) (title, body string, tags []string) {
	st := e.State
	ends := ""
	if st.Running {
		ends = " · until " + st.EndsAt.Local().Format("15:04")
	}
	session := fmt.Sprintf("session %d/%d", max(st.Session, 1), st.Settings.LongBreakAfter)
	tag := "pomodoro-" + map[string]string{
		EventWorkStart: "work-start", EventBreakStart: "break-start", EventRestart: "restart",
		EventWorkEnd: "work-end", EventBreakEnd: "break-end", EventStop: "stop",
	}[e.Kind]
	switch e.Kind {
	case EventWorkStart:
		return fmt.Sprintf("Work · %d min", st.Settings.Work), "Focus: " + session + ends, []string{"tomato", "pomodoro", tag}
	case EventRestart:
		return fmt.Sprintf("New cycle · work %d min", st.Settings.Work), "Starting " + session + ends, []string{"arrows_counterclockwise", "pomodoro", tag}
	case EventBreakStart:
		return fmt.Sprintf("%s · %d min", PhaseName(st.Phase), st.Duration/60), "Step away" + ends, []string{"coffee", "pomodoro", tag}
	case EventWorkEnd:
		return "Work session done", fmt.Sprintf("%s (%d min) is ready when you are", PhaseName(st.Phase), st.Duration/60), []string{"white_check_mark", "pomodoro", tag}
	case EventBreakEnd:
		return "Break over", fmt.Sprintf("Work session %d/%d is ready when you are", st.Completed+1, st.Settings.LongBreakAfter), []string{"bell", "pomodoro", tag}
	case EventStop:
		return "Pomodoro stopped", fmt.Sprintf("%d session(s) today", st.Today), []string{"stop_sign", "pomodoro", tag}
	}
	return "Pomodoro", e.Kind, []string{"pomodoro"}
}
