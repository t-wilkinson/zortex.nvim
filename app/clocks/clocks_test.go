package clocks

import (
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type fake struct {
	mu sync.Mutex
	t  time.Time
}

func (f *fake) now() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.t }
func (f *fake) add(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

func open(t *testing.T, path string, f *fake) *Clocks {
	t.Helper()
	c, err := OpenAt(path, f.now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c
}

func TestTimer(t *testing.T) {
	f := &fake{t: time.Date(2026, 10, 12, 9, 0, 0, 0, time.Local)}
	path := filepath.Join(t.TempDir(), "clocks.json")
	c := open(t, path, f)
	st, err := c.AddTimer("  Tea  ", 300)
	if err != nil || len(st.Timers) != 1 || st.Timers[0].Label != "Tea" || st.Timers[0].Left != 300 {
		t.Fatalf("add: %v %+v", err, st.Timers)
	}
	id := st.Timers[0].ID
	f.add(100 * time.Second)
	if st = c.State(); st.Timers[0].Left != 200 {
		t.Fatalf("left %d", st.Timers[0].Left)
	}
	st, _ = c.TimerAction(id, "pause")
	f.add(time.Hour)
	if st = c.State(); st.Timers[0].Left != 200 || st.Timers[0].Running {
		t.Fatalf("paused: %+v", st.Timers[0])
	}
	if ev := c.Tick(); len(ev) != 0 {
		t.Fatalf("paused timer fired: %v", ev)
	}
	c.TimerAction(id, "resume")
	f.add(199 * time.Second)
	if ev := c.Tick(); len(ev) != 0 {
		t.Fatal("fired early")
	}
	f.add(time.Second)
	ev := c.Tick()
	if len(ev) != 1 || ev[0].Kind != "timer" || ev[0].Label != "Tea" {
		t.Fatalf("events %+v", ev)
	}
	title, body, tags := Message(ev[0])
	if title != "Timer: Tea" || body != "5:00 timer ended at 10:05" || tags[0] != "timer" {
		t.Errorf("message %q %q %v", title, body, tags)
	}
	if st = c.State(); !st.Timers[0].Done || st.Timers[0].Running {
		t.Fatalf("done: %+v", st.Timers[0])
	}
	// restart, then remove
	if st, _ = c.TimerAction(id, "restart"); !st.Timers[0].Running || st.Timers[0].Left != 300 {
		t.Fatalf("restart: %+v", st.Timers[0])
	}
	if st, _ = c.TimerAction(id, "remove"); len(st.Timers) != 0 {
		t.Fatal("remove")
	}
	if _, err := c.TimerAction("nope", "pause"); err != ErrNotFound {
		t.Fatalf("unknown id: %v", err)
	}
	if _, err := c.AddTimer("", 0); err == nil {
		t.Fatal("zero timer accepted")
	}
}

func TestAlarm(t *testing.T) {
	f := &fake{t: time.Date(2026, 10, 12, 21, 0, 0, 0, time.Local)}
	path := filepath.Join(t.TempDir(), "clocks.json")
	c := open(t, path, f)
	if _, err := c.AddAlarm("", "25:00", "once"); err == nil {
		t.Fatal("bad time accepted")
	}
	st, err := c.AddAlarm("Wake up", "7:00", "daily")
	if err != nil || st.Alarms[0].Time != "07:00" || !st.Alarms[0].Next.Equal(time.Date(2026, 10, 13, 7, 0, 0, 0, time.Local)) {
		t.Fatalf("daily: %v %+v", err, st.Alarms)
	}
	st, _ = c.AddAlarm("Call", "21:30", "once")
	f.add(30 * time.Minute)
	ev := c.Tick()
	if len(ev) != 1 || ev[0].Label != "Call" {
		t.Fatalf("once: %+v", ev)
	}
	st = c.State()
	for _, a := range st.Alarms {
		if a.Label == "Call" && (a.Enabled || !a.Rang.Equal(time.Date(2026, 10, 12, 21, 30, 0, 0, time.Local))) {
			t.Fatalf("one-off after ringing: %+v", a)
		}
	}
	// the daily one rings and comes back tomorrow
	f.add(10 * time.Hour) // 07:30 next day
	ev = c.Tick()
	if len(ev) != 0 {
		t.Fatalf("30 minutes late should be settled silently: %+v", ev)
	}
	st = c.State()
	if st.Alarms[0].Label != "Wake up" || !st.Alarms[0].Next.Equal(time.Date(2026, 10, 14, 7, 0, 0, 0, time.Local)) {
		t.Fatalf("daily next: %+v", st.Alarms[0])
	}
	f.t = time.Date(2026, 10, 14, 7, 0, 30, 0, time.Local)
	if ev = c.Tick(); len(ev) != 1 || ev[0].Kind != "alarm" {
		t.Fatalf("daily ring: %+v", ev)
	}
	// disable / enable / remove
	id := st.Alarms[0].ID
	st, _ = c.AlarmAction(id, "disable")
	if st.Alarms[0].Enabled {
		t.Fatal("disable")
	}
	st, _ = c.AlarmAction(id, "enable")
	if !st.Alarms[0].Next.Equal(time.Date(2026, 10, 15, 7, 0, 0, 0, time.Local)) {
		t.Fatalf("enable: %+v", st.Alarms[0])
	}
	st, _ = c.AlarmAction(id, "remove")
	if len(st.Alarms) != 1 {
		t.Fatal("remove")
	}
}

func TestStopwatchAndPersistence(t *testing.T) {
	f := &fake{t: time.Date(2026, 10, 12, 9, 0, 0, 0, time.Local)}
	path := filepath.Join(t.TempDir(), "clocks.json")
	c := open(t, path, f)
	c.StopwatchAction("start")
	f.add(1500 * time.Millisecond)
	c.StopwatchAction("lap")
	f.add(time.Second)
	st, _ := c.StopwatchAction("toggle") // pause
	if st.Stopwatch.Running || st.Stopwatch.Elapsed != 2500 || len(st.Stopwatch.Laps) != 1 || st.Stopwatch.Laps[0] != 1500 {
		t.Fatalf("stopwatch %+v", st.Stopwatch)
	}
	f.add(time.Minute)
	c.StopwatchAction("start")
	f.add(500 * time.Millisecond)
	c.AddTimer("Oven", 600)
	c.AddAlarm("Lunch", "12:00", "daily")
	c.Close()

	// reopened: everything is still there, the stopwatch still running
	c2 := open(t, path, f)
	st = c2.State()
	if !st.Stopwatch.Running || st.Stopwatch.Elapsed != 3000 || len(st.Timers) != 1 || len(st.Alarms) != 1 {
		t.Fatalf("reopened: %+v", st)
	}
	st, _ = c2.StopwatchAction("reset")
	if st.Stopwatch.Running || st.Stopwatch.Elapsed != 0 || len(st.Stopwatch.Laps) != 0 {
		t.Fatalf("reset %+v", st.Stopwatch)
	}
}

func TestFiresOnItsOwn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "clocks.json")
	c, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	got := make(chan Event, 1)
	c.Notify = func(e Event) { got <- e }
	c.AddTimer("quick", 1)
	select {
	case e := <-got:
		if e.Label != "quick" {
			t.Fatalf("event %+v", e)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timer never fired")
	}
}
