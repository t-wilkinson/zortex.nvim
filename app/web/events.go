package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Live updates: GET /api/events is a server-sent event stream, so open pages
// redraw as soon as something changes instead of on their next poll:
//
//	event: notes      {"rels": ["projects.zortex", ...]}  notes added, changed or removed
//	event: xp         {}                                  a new XP summary from Neovim
//	event: pomodoro   {}                                  the clock changed
//	event: clocks     {}                                  timers, alarms or the stopwatch changed
//
// Notes edited in Neovim reach the server through Syncthing; the server
// notices on its next rescan (-poll).

type liveEvent struct {
	kind string
	data []byte
}

type eventHub struct {
	mu     sync.Mutex
	subs   map[chan liveEvent]struct{}
	closed bool
}

func (h *eventHub) subscribe() chan liveEvent {
	h.mu.Lock()
	defer h.mu.Unlock()
	ch := make(chan liveEvent, 16)
	if h.closed {
		close(ch)
		return ch
	}
	if h.subs == nil {
		h.subs = map[chan liveEvent]struct{}{}
	}
	h.subs[ch] = struct{}{}
	return ch
}

func (h *eventHub) unsubscribe(ch chan liveEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.subs[ch]; ok {
		delete(h.subs, ch)
		close(ch)
	}
}

// publish sends to every page; a page that isn't keeping up misses it (it
// still polls now and then).
func (h *eventHub) publish(kind string, data any) {
	raw, err := json.Marshal(data)
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- liveEvent{kind, raw}:
		default:
		}
	}
}

// close ends every stream (shutdown).
func (h *eventHub) close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for ch := range h.subs {
		close(ch)
	}
	h.subs = nil
}

func (h *eventHub) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}

const eventKeepalive = 25 * time.Second

func (s *Server) apiEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no") // nginx: don't buffer the stream
	ch := s.events.subscribe()
	defer s.events.unsubscribe(ch)
	fmt.Fprint(w, "retry: 5000\n: hello\n\n")
	fl.Flush()
	t := time.NewTicker(eventKeepalive)
	defer t.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", ev.kind, ev.data)
			fl.Flush()
		case <-t.C:
			fmt.Fprint(w, ": keepalive\n\n")
			fl.Flush()
		}
	}
}

// notesChanged tells open pages which notes changed.
func (s *Server) notesChanged(rels []string) {
	if len(rels) == 0 {
		return
	}
	rels = append([]string(nil), rels...)
	sort.Strings(rels)
	s.events.publish("notes", map[string]any{"rels": rels})
}

// checkXPFile announces a new .z/xp_summary.json (synced from Neovim).
func (s *Server) checkXPFile() {
	st, err := os.Stat(filepath.Join(s.cfg.Root, ".z", xpFile))
	var mod time.Time
	if err == nil {
		mod = st.ModTime()
	}
	s.xpFileMu.Lock()
	changed := !mod.Equal(s.xpFileSeen)
	first := s.xpFileSeen.IsZero() && !s.xpFileChecked
	s.xpFileSeen, s.xpFileChecked = mod, true
	s.xpFileMu.Unlock()
	if changed && !first {
		s.events.publish("xp", map[string]any{})
	}
}
