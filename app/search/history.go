package search

import (
	"encoding/json"
	"errors"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// History is what was opened from the web app's search, kept by the server
// (search_history.json in its -data folder) and apart from the plugin's
// notes_dir/.z/search_history.json, so a synced notes folder never gets two
// writers. It ranks the same way as the plugin's services/search_history:
//
//	notes     a frecency score per note, decaying by FileDecay per day
//	sections  a score per section (note + breadcrumb), decaying by
//	          SectionDecay per day; each ancestor gets Propagation of it per
//	          level; only the MaxSections strongest are kept
//
// A score is stored as (value, time) and decayed on read; opening adds 1.
// Search adds 50·ln(1+note) + 30·ln(1+section) points, never more than a
// better word match (100 points).
type History struct {
	FileDecay    float64
	SectionDecay float64
	Propagation  float64
	MaxSections  int

	mu   sync.Mutex
	path string
	data historyData
}

type historyData struct {
	Version  int                     `json:"version"`
	Files    map[string]historyScore `json:"files"`
	Sections map[string]historyScore `json:"sections"`
}

type historyScore struct {
	Value float64 `json:"value"`
	Time  int64   `json:"time"` // unix seconds
}

const (
	historyFileWeight    = 50
	historySectionWeight = 30
)

// OpenHistory reads the history at path (a missing file is an empty one).
// An empty path keeps it in memory.
func OpenHistory(path string) (*History, error) {
	h := &History{FileDecay: 0.1, SectionDecay: 0.1, Propagation: 0.7, MaxSections: 50, path: path}
	h.data = historyData{Version: 1, Files: map[string]historyScore{}, Sections: map[string]historyScore{}}
	if path == "" {
		return h, nil
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return h, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(raw, &h.data); err != nil {
		return nil, err
	}
	if h.data.Files == nil {
		h.data.Files = map[string]historyScore{}
	}
	if h.data.Sections == nil {
		h.data.Sections = map[string]historyScore{}
	}
	return h, nil
}

func decayed(s historyScore, rate float64, now time.Time) float64 {
	if s.Time == 0 {
		return 0
	}
	days := math.Max(0, float64(now.Unix()-s.Time)/86400)
	return s.Value * math.Exp(-rate*days)
}

func sectionKey(rel, breadcrumb string) string { return rel + "\n" + breadcrumb }

// Record notes that rel was opened from search; breadcrumbs are the
// section's and its ancestors' (innermost first), none for a line.
func (h *History) Record(rel string, breadcrumbs []string, now time.Time) error {
	if h == nil || rel == "" {
		return nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	bump := func(m map[string]historyScore, key string, amount, rate float64) {
		m[key] = historyScore{Value: decayed(m[key], rate, now) + amount, Time: now.Unix()}
	}
	bump(h.data.Files, rel, 1, h.FileDecay)
	w := 1.0
	for _, bc := range breadcrumbs {
		bump(h.data.Sections, sectionKey(rel, bc), w, h.SectionDecay)
		w *= h.Propagation
	}
	h.prune(now)
	return h.save()
}

func (h *History) prune(now time.Time) {
	if len(h.data.Sections) > h.MaxSections {
		keys := make([]string, 0, len(h.data.Sections))
		for k := range h.data.Sections {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool {
			a, b := decayed(h.data.Sections[keys[i]], h.SectionDecay, now), decayed(h.data.Sections[keys[j]], h.SectionDecay, now)
			if a != b {
				return a > b
			}
			return keys[i] < keys[j]
		})
		for _, k := range keys[h.MaxSections:] {
			delete(h.data.Sections, k)
		}
	}
	for k, s := range h.data.Files {
		if decayed(s, h.FileDecay, now) < 0.01 {
			delete(h.data.Files, k)
		}
	}
}

func (h *History) save() error {
	if h.path == "" {
		return nil
	}
	raw, err := json.MarshalIndent(h.data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(h.path), 0o750); err != nil {
		return err
	}
	tmp := h.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, h.path)
}

// boost: the points a section of rel gets from the history.
func (h *History) boost(rel, breadcrumb string, now time.Time) int {
	if h == nil {
		return 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	f := decayed(h.data.Files[rel], h.FileDecay, now)
	s := decayed(h.data.Sections[sectionKey(rel, breadcrumb)], h.SectionDecay, now)
	return int(math.Round(historyFileWeight*math.Log1p(f) + historySectionWeight*math.Log1p(s)))
}

// Opened: the decayed score of a note (tests, diagnostics).
func (h *History) Opened(rel string, now time.Time) float64 {
	if h == nil {
		return 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	return decayed(h.data.Files[rel], h.FileDecay, now)
}
