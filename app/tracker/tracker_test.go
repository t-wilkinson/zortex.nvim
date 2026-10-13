package tracker

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time      { return c.t }
func (c *clock) add(d time.Duration) { c.t = c.t.Add(d) }
func target(key string) *Target      { return &Target{Rel: "p.zortex", Key: key, Text: key} }
func running(on bool) Clocks         { return Clocks{Running: on} }
func bounded(end time.Time) Clocks   { return Clocks{Running: true, Bound: end} }

type book struct {
	writes []string
	fail   bool
}

func (b *book) write(t Target, minutes int) (Target, error) {
	if b.fail {
		return t, errors.New("note changed")
	}
	b.writes = append(b.writes, t.Key+":"+itoa(minutes))
	return t, nil
}

func itoa(n int) string {
	return string(rune('0'+n/100%10)) + string(rune('0'+n/10%10)) + string(rune('0'+n%10))
}

func open(t *testing.T) (*Tracker, *clock, *book) {
	t.Helper()
	c := &clock{t: time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)}
	b := &book{}
	tr, err := OpenAt(filepath.Join(t.TempDir(), "track.json"), b.write, c.now)
	if err != nil {
		t.Fatal(err)
	}
	return tr, c, b
}

func TestCalendarTaskCountsWhileClocksRun(t *testing.T) {
	tr, c, b := open(t)
	cal := target("deep work")
	tr.Sync(running(true), cal) // start
	c.add(25 * time.Minute)
	st, _ := tr.Sync(running(false), cal) // pomodoro work phase ends
	if len(b.writes) != 1 || b.writes[0] != "deep work:025" || st.Pending != 0 {
		t.Fatalf("writes %v pending %d", b.writes, st.Pending)
	}
	// a break: nothing counts
	c.add(5 * time.Minute)
	tr.Sync(running(false), cal)
	if len(b.writes) != 1 {
		t.Fatal("counted a break")
	}
}

func TestShortStretchesWaitAndAddUp(t *testing.T) {
	tr, c, b := open(t)
	task := Target{Rel: "p.zortex", Key: "a"}
	tr.Pin(task)
	tr.Sync(running(true), nil)
	c.add(40 * time.Second)
	st, _ := tr.Sync(running(false), nil) // paused at 0:40: not written yet
	if len(b.writes) != 0 || st.Pending != 40000 {
		t.Fatalf("writes %v pending %d", b.writes, st.Pending)
	}
	c.add(10 * time.Minute) // paused
	tr.Sync(running(true), nil)
	c.add(30 * time.Second)
	tr.Sync(running(false), nil) // 1:10 in all
	if len(b.writes) != 1 || b.writes[0] != "a:001" {
		t.Fatalf("writes %v", b.writes)
	}
}

func TestSwitchingTasks(t *testing.T) {
	tr, c, b := open(t)
	tr.Sync(running(true), target("first"))
	c.add(20 * time.Minute)
	// the calendar moves on while the clock runs: first gets 20, second starts
	st, _ := tr.Sync(running(true), target("second"))
	if len(b.writes) != 1 || b.writes[0] != "first:020" || st.Task.Key != "second" || st.Since != c.t {
		t.Fatalf("writes %v state %+v", b.writes, st)
	}
	c.add(30 * time.Second)
	// picked by hand after 30 s: second gets nothing (under a minute)
	tr.Pin(*target("third"))
	c.add(2 * time.Minute)
	tr.Sync(running(true), target("fourth")) // pinned: the calendar no longer matters
	tr.Sync(running(false), target("fourth"))
	if len(b.writes) != 2 || b.writes[1] != "third:002" {
		t.Fatalf("writes %v", b.writes)
	}
	// back to the calendar; off
	st, _ = tr.Follow(target("fourth"))
	if st.Mode != ModeCalendar || st.Task.Key != "fourth" {
		t.Fatalf("follow %+v", st)
	}
	tr.Sync(running(true), target("fourth"))
	c.add(3 * time.Minute)
	st, _ = tr.Off()
	if st.Task != nil || len(b.writes) != 3 || b.writes[2] != "fourth:003" {
		t.Fatalf("off %+v %v", st, b.writes)
	}
	tr.Sync(running(true), target("fifth")) // off: the calendar is ignored
	c.add(5 * time.Minute)
	tr.Sync(running(false), target("fifth"))
	if len(b.writes) != 3 {
		t.Fatalf("tracked while off: %v", b.writes)
	}
}

func TestPhaseEndedUnseen(t *testing.T) {
	tr, c, b := open(t)
	end := c.t.Add(25 * time.Minute)
	tr.Sync(bounded(end), target("x"))
	c.add(2 * time.Hour) // the server only noticed much later
	tr.Sync(running(false), target("x"))
	if len(b.writes) != 1 || b.writes[0] != "x:025" {
		t.Fatalf("writes %v", b.writes)
	}
}

func TestNoCalendarTaskNoCount(t *testing.T) {
	tr, c, b := open(t)
	tr.Sync(running(true), nil)
	c.add(10 * time.Minute)
	st, _ := tr.Sync(running(true), target("later")) // an entry starts: count from now
	c.add(2 * time.Minute)
	tr.Sync(running(false), target("later"))
	if len(b.writes) != 1 || b.writes[0] != "later:002" || st.Counted != 0 {
		t.Fatalf("writes %v state %+v", b.writes, st)
	}
}

func TestFailedWriteIsKeptAndPersisted(t *testing.T) {
	tr, c, b := open(t)
	b.fail = true
	tr.Pin(Target{Rel: "p.zortex", Key: "a"})
	tr.Sync(running(true), nil)
	c.add(5 * time.Minute)
	st, err := tr.Sync(running(false), nil)
	if err == nil || st.Pending != 300000 || st.Error == "" {
		t.Fatalf("state %+v err %v", st, err)
	}
	// reopened (server restart): still there, written on the next stop
	b.fail = false
	tr2, err := OpenAt(tr.path, b.write, c.now)
	if err != nil {
		t.Fatal(err)
	}
	if st := tr2.State(); st.Pending != 300000 || st.Task.Key != "a" || st.Mode != ModePinned {
		t.Fatalf("reopened %+v", st)
	}
	st, _ = tr2.Flush()
	if len(b.writes) != 1 || b.writes[0] != "a:005" || st.Error != "" {
		t.Fatalf("flush %v %+v", b.writes, st)
	}
}
