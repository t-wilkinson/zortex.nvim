package pomodoro

import (
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (f *fakeClock) now() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.t }
func (f *fakeClock) add(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

func newClock(t *testing.T, s Settings) (*Clock, *fakeClock, *[]string) {
	t.Helper()
	fc := &fakeClock{t: time.Date(2026, 10, 12, 9, 0, 0, 0, time.Local)}
	c, err := Open(filepath.Join(t.TempDir(), "pomodoro.json"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	c.SetClock(fc.now)
	var mu sync.Mutex
	events := &[]string{}
	c.Notify = func(e Event) { mu.Lock(); *events = append(*events, e.Kind); mu.Unlock() }
	if _, err := c.Update(s); err != nil {
		t.Fatal(err)
	}
	return c, fc, events
}

func TestCycleAndEvents(t *testing.T) {
	s := Settings{Work: 25, ShortBreak: 5, LongBreak: 15, LongBreakAfter: 2, AutoStartBreak: true, AutoStartWork: true}
	c, fc, _ := newClock(t, s)
	st, _ := c.Start()
	if st.Phase != Work || !st.Running || st.Session != 1 || st.Remaining != 25*60 {
		t.Fatalf("start: %+v", st)
	}
	var got []string
	step := func(d time.Duration) string { fc.add(d); return c.Tick() }
	got = append(got, step(25*time.Minute)) // -> short break
	got = append(got, step(5*time.Minute))  // -> work 2
	got = append(got, step(25*time.Minute)) // -> long break
	got = append(got, step(15*time.Minute)) // -> new cycle
	want := []string{EventBreakStart, EventWorkStart, EventBreakStart, EventRestart}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("events %v, want %v", got, want)
		}
	}
	st = c.State()
	if st.Phase != Work || st.Session != 1 || st.Completed != 0 || st.Today != 2 {
		t.Fatalf("after cycle: %+v", st)
	}
}

func TestManualStartPauseSkip(t *testing.T) {
	s := Settings{Work: 25, ShortBreak: 5, LongBreak: 15, LongBreakAfter: 4}
	c, fc, _ := newClock(t, s)
	c.Start()
	fc.add(10 * time.Minute)
	st, _ := c.Pause()
	if st.Running || st.Remaining != 15*60 {
		t.Fatalf("pause: %+v", st)
	}
	fc.add(time.Hour) // paused time doesn't count
	st, _ = c.Resume()
	if !st.Running || st.Remaining != 15*60 {
		t.Fatalf("resume: %+v", st)
	}
	fc.add(15 * time.Minute)
	if ev := c.Tick(); ev != EventWorkEnd {
		t.Fatalf("auto_start_break off: got %q", ev)
	}
	st = c.State()
	if st.Phase != ShortBreak || st.Running || st.Started || st.Remaining != 5*60 {
		t.Fatalf("waiting: %+v", st)
	}
	st, _ = c.Skip() // skip the waiting break
	if st.Phase != Work || !st.Running || st.Session != 2 {
		t.Fatalf("skip break: %+v", st)
	}
	st, _ = c.Stop()
	if st.Phase != Idle || st.Running {
		t.Fatalf("stop: %+v", st)
	}
	st, _ = c.Start()
	if st.Session != 1 {
		t.Fatalf("start after stop begins a new cycle: %+v", st)
	}
}

func TestPersistAndCatchUp(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "p.json")
	c, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now().Add(-26 * time.Minute)
	c.SetClock(func() time.Time { return start })
	c.Start()
	c.Close()
	// reopened 26 minutes later: the work session ended while "down"
	c2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	st := c2.State()
	if st.Phase != ShortBreak || !st.Running || st.Completed != 1 {
		t.Fatalf("caught up: %+v", st)
	}
}

func TestStateDoesNotSwallowExpiry(t *testing.T) {
	c, fc, _ := newClock(t, Settings{Work: 1, ShortBreak: 1, LongBreak: 1, LongBreakAfter: 4, AutoStartBreak: true})
	c.Start()
	fc.add(90 * time.Second)
	if st := c.State(); st.Phase != Work || st.Remaining != 0 {
		t.Fatalf("read moved the clock: %+v", st)
	}
	if ev := c.Tick(); ev != EventBreakStart {
		t.Fatalf("tick after read: %q", ev)
	}
}

func TestSettingsValidation(t *testing.T) {
	c, _, _ := newClock(t, DefaultSettings)
	if _, err := c.Update(Settings{Work: 0, ShortBreak: 5, LongBreak: 15, LongBreakAfter: 4}); err == nil {
		t.Fatal("expected error")
	}
}
