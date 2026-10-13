package web

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/tracker"
)

// Time spent per day, for Neovim's daily review: every minute the tracker
// writes to a task's @spent is also added to notes/.z/time_spent.json, which
// Syncthing carries to Neovim like the XP summary (Neovim never writes it):
//
//	{"version": 1, "days": {"2026-10-13": [{"rel", "lnum", "id"?, "text", "minutes"}]}}
//
// Days older than timeSpentKeep are dropped.

const (
	timeSpentFile = "time_spent.json"
	timeSpentKeep = 120 * 24 * time.Hour
)

type spentTask struct {
	Rel     string `json:"rel"`
	Lnum    int    `json:"lnum"`
	ID      string `json:"id,omitempty"`
	Text    string `json:"text"`
	Key     string `json:"key"`
	Minutes int    `json:"minutes"`
}

type timeSpent struct {
	Version int                    `json:"version"`
	Days    map[string][]spentTask `json:"days"`
}

var timeSpentMu sync.Mutex

func (s *Server) timeSpentPath() string { return filepath.Join(s.cfg.Root, ".z", timeSpentFile) }

// addTimeSpent records e under the day it was written.
func (s *Server) addTimeSpent(e tracker.Entry) error {
	timeSpentMu.Lock()
	defer timeSpentMu.Unlock()
	path := s.timeSpentPath()
	ts := timeSpent{Version: 1, Days: map[string][]spentTask{}}
	if raw, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(raw, &ts)
		if ts.Days == nil {
			ts.Days = map[string][]spentTask{}
		}
	}
	day := e.At.Format("2006-01-02")
	list := ts.Days[day]
	found := false
	for i := range list {
		if list[i].Key == e.Task.Key {
			list[i].Minutes += e.Minutes
			list[i].Lnum, list[i].Text, list[i].Rel = e.Task.Lnum, e.Task.Text, e.Task.Rel
			found = true
		}
	}
	if !found {
		list = append(list, spentTask{Rel: e.Task.Rel, Lnum: e.Task.Lnum, ID: e.Task.ID, Text: e.Task.Text, Key: e.Task.Key, Minutes: e.Minutes})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].Minutes > list[j].Minutes })
	ts.Days[day] = list
	cutoff := e.At.Add(-timeSpentKeep).Format("2006-01-02")
	for d := range ts.Days {
		if d < cutoff {
			delete(ts.Days, d)
		}
	}
	raw, err := json.MarshalIndent(ts, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o775); err != nil {
		return err
	}
	// a temporary name Syncthing ignores, then an atomic rename
	tmp, err := os.CreateTemp(filepath.Dir(path), ".syncthing."+timeSpentFile+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(raw, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	_ = os.Chmod(tmp.Name(), 0o664)
	return os.Rename(tmp.Name(), path)
}
