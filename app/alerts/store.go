// Package alerts is the notification side of `zortex serve`: the scheduled
// notifications Neovim syncs from calendar.zortex (POST /notify), persisted in
// a JSON file, and the sender that delivers them through ntfy when they are
// due.
//
// The store keeps one list per user. A sync replaces the user's pending
// notifications with the incoming set (matched by deduplication key, so
// unchanged ones keep their identity); sent notifications are kept for a week
// so the calendar can still show what already fired today.
package alerts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Notification is one scheduled notification.
type Notification struct {
	ID            int64    `json:"id"`
	UserID        string   `json:"user_id"`
	EntryID       string   `json:"entry_id,omitempty"`
	Title         string   `json:"title"`
	Message       string   `json:"message"`
	ScheduledTime int64    `json:"scheduled_time"` // unix seconds
	Priority      string   `json:"priority,omitempty"`
	Tags          []string `json:"tags,omitempty"`
	CreatedAt     int64    `json:"created_at"`
	SentAt        int64    `json:"sent_at,omitempty"` // 0: pending
	Skipped       bool     `json:"skipped,omitempty"` // too late to send: marked sent without sending
	DedupKey      string   `json:"deduplication_key,omitempty"`
}

// Pending reports whether n has not been sent yet.
func (n *Notification) Pending() bool { return n.SentAt == 0 }

// Incoming is a notification as Neovim sends it.
type Incoming struct {
	EntryID       string   `json:"entry_id"`
	Title         string   `json:"title"`
	Message       string   `json:"message"`
	ScheduledTime int64    `json:"scheduled_time"`
	Priority      string   `json:"priority"`
	Tags          []string `json:"tags"`
	DedupKey      string   `json:"deduplication_key"`
}

func (in *Incoming) key() string {
	if in.DedupKey != "" {
		return in.DedupKey
	}
	if in.EntryID != "" {
		return fmt.Sprintf("%s_%d", in.EntryID, in.ScheduledTime)
	}
	// No key at all: identify it by what it says and when
	return fmt.Sprintf("%s|%s|%d", in.Title, in.Message, in.ScheduledTime)
}

// SyncResult reports what a sync changed.
type SyncResult struct {
	Success   bool   `json:"success"`
	Unchanged bool   `json:"unchanged,omitempty"` // same manifest as the last sync: nothing done
	Added     int    `json:"added"`
	Updated   int    `json:"updated"`
	Removed   int    `json:"removed"`
	Total     int    `json:"total"`
	Manifest  string `json:"manifest"`
}

type fileData struct {
	Version       int                       `json:"version"`
	NextID        int64                     `json:"next_id"`
	Notifications []*Notification           `json:"notifications"`
	Manifests     map[string]manifestRecord `json:"manifests,omitempty"` // user -> last sync
}

type manifestRecord struct {
	Hash   string `json:"hash"`
	SyncAt int64  `json:"sync_at"`
}

// Store is the persisted notification list. Safe for concurrent use.
type Store struct {
	path string
	now  func() time.Time

	mu   sync.Mutex
	data fileData
}

// Open loads (or creates) the store at path.
func Open(path string) (*Store, error) {
	s := &Store{path: path, now: time.Now, data: fileData{Version: 1, NextID: 1, Manifests: map[string]manifestRecord{}}}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return s, s.save()
	case err != nil:
		return nil, err
	}
	if err := json.Unmarshal(raw, &s.data); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if s.data.Manifests == nil {
		s.data.Manifests = map[string]manifestRecord{}
	}
	if s.data.NextID < 1 {
		s.data.NextID = 1
	}
	for _, n := range s.data.Notifications {
		if n.ID >= s.data.NextID {
			s.data.NextID = n.ID + 1
		}
	}
	return s, nil
}

// SetClock replaces time.Now (tests).
func (s *Store) SetClock(now func() time.Time) { s.now = now }

// save writes the file atomically. Callers hold mu (or own s exclusively).
func (s *Store) save() error {
	raw, err := json.MarshalIndent(&s.data, "", " ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Manifest is a stable hash of a set of incoming notifications, so a client
// can tell whether a sync would change anything.
func Manifest(list []Incoming) string {
	keys := make([]string, 0, len(list))
	for i := range list {
		in := &list[i]
		tags := append([]string(nil), in.Tags...)
		sort.Strings(tags)
		keys = append(keys, strings.Join([]string{in.key(), in.Title, in.Message, fmt.Sprint(in.ScheduledTime), in.Priority, strings.Join(tags, ",")}, "\x1f"))
	}
	sort.Strings(keys)
	h := sha256.Sum256([]byte(strings.Join(keys, "\x1e")))
	return hex.EncodeToString(h[:8])
}

// Sync replaces user's pending notifications with list: pending ones whose
// key is not in list are removed, the others are added or updated in place.
// Sent notifications are never touched. Notifications already in the past
// are ignored (they would fire immediately).
func (s *Store) Sync(user string, list []Incoming) (SyncResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now().Unix()

	var future []Incoming
	for _, in := range list {
		if in.ScheduledTime == 0 {
			in.ScheduledTime = now
		}
		if in.ScheduledTime >= now-60 {
			future = append(future, in)
		}
	}
	hash := Manifest(future)
	res := SyncResult{Success: true, Total: len(future), Manifest: hash}
	if rec, ok := s.data.Manifests[user]; ok && rec.Hash == hash {
		res.Unchanged = true
		return res, nil
	}

	incoming := map[string]*Incoming{}
	for i := range future {
		incoming[future[i].key()] = &future[i]
	}
	sentKeys := map[string]bool{}
	kept := s.data.Notifications[:0]
	seen := map[string]bool{}
	for _, n := range s.data.Notifications {
		if n.UserID != user {
			kept = append(kept, n)
			continue
		}
		if !n.Pending() {
			sentKeys[n.DedupKey] = true
			kept = append(kept, n)
			continue
		}
		in, ok := incoming[n.DedupKey]
		if !ok || seen[n.DedupKey] {
			res.Removed++
			continue
		}
		seen[n.DedupKey] = true
		if n.Title != in.Title || n.Message != in.Message || n.ScheduledTime != in.ScheduledTime || n.Priority != in.Priority || !equalStrings(n.Tags, in.Tags) {
			n.Title, n.Message, n.ScheduledTime, n.Priority, n.Tags, n.EntryID = in.Title, in.Message, in.ScheduledTime, in.Priority, in.Tags, in.EntryID
			res.Updated++
		}
		kept = append(kept, n)
	}
	s.data.Notifications = kept
	for i := range future {
		in := &future[i]
		key := in.key()
		if seen[key] || sentKeys[key] {
			continue
		}
		seen[key] = true
		s.insert(user, in, now)
		res.Added++
	}
	s.data.Manifests[user] = manifestRecord{Hash: hash, SyncAt: now}
	s.sortLocked()
	return res, s.save()
}

func (s *Store) insert(user string, in *Incoming, now int64) *Notification {
	title := in.Title
	if title == "" {
		title = "Zortex Notification"
	}
	n := &Notification{
		ID:            s.data.NextID,
		UserID:        user,
		EntryID:       in.EntryID,
		Title:         title,
		Message:       in.Message,
		ScheduledTime: in.ScheduledTime,
		Priority:      in.Priority,
		Tags:          in.Tags,
		CreatedAt:     now,
		DedupKey:      in.key(),
	}
	if n.ScheduledTime == 0 {
		n.ScheduledTime = now
	}
	s.data.NextID++
	s.data.Notifications = append(s.data.Notifications, n)
	return n
}

// Add schedules one notification. A notification with the same key that is
// still pending (or was already sent) is not added twice.
func (s *Store) Add(user string, in Incoming) (*Notification, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := in.key()
	for _, n := range s.data.Notifications {
		if n.UserID == user && n.DedupKey == key {
			return n, false, nil
		}
	}
	n := s.insert(user, &in, s.now().Unix())
	s.sortLocked()
	return n, true, s.save()
}

// Clear removes user's pending notifications (and forgets the last manifest).
func (s *Store) Clear(user string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.data.Notifications[:0]
	removed := 0
	for _, n := range s.data.Notifications {
		if n.UserID == user && n.Pending() {
			removed++
			continue
		}
		kept = append(kept, n)
	}
	s.data.Notifications = kept
	delete(s.data.Manifests, user)
	return removed, s.save()
}

// Pending returns pending notifications (all users when user is ""), by time.
func (s *Store) Pending(user string) []Notification {
	return s.filter(func(n *Notification) bool { return n.Pending() && (user == "" || n.UserID == user) })
}

// Since returns every notification scheduled at or after t, by time.
func (s *Store) Since(t time.Time) []Notification {
	ts := t.Unix()
	return s.filter(func(n *Notification) bool { return n.ScheduledTime >= ts })
}

// Due returns pending notifications scheduled at or before now.
func (s *Store) Due(now time.Time) []Notification {
	ts := now.Unix()
	return s.filter(func(n *Notification) bool { return n.Pending() && n.ScheduledTime <= ts })
}

func (s *Store) filter(keep func(*Notification) bool) []Notification {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Notification
	for _, n := range s.data.Notifications {
		if keep(n) {
			c := *n
			c.Tags = append([]string(nil), n.Tags...)
			out = append(out, c)
		}
	}
	return out
}

// MarkSent records that notification id was sent (skipped: dropped as too late).
func (s *Store) MarkSent(id int64, at time.Time, skipped bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, n := range s.data.Notifications {
		if n.ID == id {
			n.SentAt, n.Skipped = at.Unix(), skipped
			return s.save()
		}
	}
	return nil
}

// Cleanup drops sent notifications older than keepSent and pending ones
// older than keepStale. Returns how many were removed.
func (s *Store) Cleanup(now time.Time, keepSent, keepStale time.Duration) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sentCut, staleCut := now.Add(-keepSent).Unix(), now.Add(-keepStale).Unix()
	kept := s.data.Notifications[:0]
	removed := 0
	for _, n := range s.data.Notifications {
		if (!n.Pending() && n.SentAt < sentCut) || (n.Pending() && n.ScheduledTime < staleCut) {
			removed++
			continue
		}
		kept = append(kept, n)
	}
	s.data.Notifications = kept
	if removed == 0 {
		return 0, nil
	}
	return removed, s.save()
}

func (s *Store) sortLocked() {
	sort.SliceStable(s.data.Notifications, func(i, j int) bool {
		a, b := s.data.Notifications[i], s.data.Notifications[j]
		if a.ScheduledTime != b.ScheduledTime {
			return a.ScheduledTime < b.ScheduledTime
		}
		return a.ID < b.ID
	})
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
