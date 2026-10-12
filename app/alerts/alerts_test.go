package alerts

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestSyncDiffsAndManifest(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "n.json"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)
	s.SetClock(func() time.Time { return now })
	at := now.Add(time.Hour).Unix()
	list := []Incoming{
		{Title: "Dentist", Message: "-", ScheduledTime: at, DedupKey: "a"},
		{Title: "Lunch", Message: "-", ScheduledTime: at + 600, DedupKey: "b"},
		{Title: "Past", Message: "-", ScheduledTime: now.Add(-time.Hour).Unix(), DedupKey: "c"},
	}
	r, _ := s.Sync("u", list)
	if r.Added != 2 || r.Total != 2 {
		t.Fatalf("first sync: %+v", r)
	}
	r, _ = s.Sync("u", list)
	if !r.Unchanged {
		t.Fatalf("same manifest should be unchanged: %+v", r)
	}
	list[1].Title = "Lunch with Sam"
	list = list[1:] // "a" removed
	r, _ = s.Sync("u", list)
	if r.Removed != 1 || r.Updated != 1 || r.Added != 0 {
		t.Fatalf("diff sync: %+v", r)
	}
	if p := s.Pending("u"); len(p) != 1 || p[0].Title != "Lunch with Sam" {
		t.Fatalf("pending: %+v", p)
	}
	// reopen: persisted
	s2, _ := Open(s.path)
	if p := s2.Pending(""); len(p) != 1 {
		t.Fatalf("reloaded: %+v", p)
	}
}

func TestSenderPublishesAndSkipsLate(t *testing.T) {
	var got []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		got = append(got, m)
	}))
	defer srv.Close()
	s, _ := Open(filepath.Join(t.TempDir(), "n.json"))
	now := time.Now()
	s.Add("u", Incoming{Title: "Due", Message: "x", ScheduledTime: now.Add(-time.Minute).Unix(), DedupKey: "1", Tags: []string{"calendar"}, Priority: "p1"})
	s.Add("u", Incoming{Title: "Very late", Message: "x", ScheduledTime: now.Add(-5 * time.Hour).Unix(), DedupKey: "2"})
	s.Add("u", Incoming{Title: "Later", Message: "x", ScheduledTime: now.Add(time.Hour).Unix(), DedupKey: "3"})
	snd := &Sender{Store: s, Ntfy: &Ntfy{URL: srv.URL, Topic: "t"}, Logger: log.New(io.Discard, "", 0)}
	if n := snd.SendDue(context.Background(), now); n != 1 {
		t.Fatalf("sent %d", n)
	}
	if len(got) != 1 || got[0]["title"] != "Due" || got[0]["topic"] != "t" || got[0]["priority"] != float64(4) {
		t.Fatalf("published %+v", got)
	}
	if p := s.Pending("u"); len(p) != 1 || p[0].Title != "Later" {
		t.Fatalf("pending after send: %+v", p)
	}
}
