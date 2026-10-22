package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
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
//	event: open       {"path": "/n/x.zortex#L3", "token": "…"}  sent to one tab: show this (open.go)
//
// Notes edited in Neovim reach the server through Syncthing; the server
// notices on its next rescan (-poll).

type liveEvent struct {
	kind string
	data []byte
}

type eventHub struct {
	mu     sync.Mutex
	subs   map[chan liveEvent]*eventClient
	closed bool
}

// eventClient is an open page: the id it gave (?client=, one per tab), the
// address it connects from, and when it connected and was last focused.
type eventClient struct {
	id, addr  string
	connected time.Time
	focused   time.Time
}

func (h *eventHub) subscribe(c *eventClient) chan liveEvent {
	h.mu.Lock()
	defer h.mu.Unlock()
	ch := make(chan liveEvent, 16)
	if h.closed {
		close(ch)
		return ch
	}
	if h.subs == nil {
		h.subs = map[chan liveEvent]*eventClient{}
	}
	if c == nil {
		c = &eventClient{}
	}
	c.connected = time.Now()
	h.subs[ch] = c
	return ch
}

// focus records that the page with this id was focused.
func (h *eventHub) focus(id string) {
	if id == "" {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	now := time.Now()
	for _, c := range h.subs {
		if c.id == id {
			c.focused = now
		}
	}
}

// sendToLatest sends to the page from addr that was focused (else
// connected) most recently; false when there is none.
func (h *eventHub) sendToLatest(addr, kind string, data any) bool {
	raw, err := json.Marshal(data)
	if err != nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	var best chan liveEvent
	var bestAt time.Time
	for ch, c := range h.subs {
		if c.id == "" || c.addr != addr {
			continue
		}
		at := c.focused
		if at.IsZero() {
			at = c.connected
		}
		if best == nil || at.After(bestAt) {
			best, bestAt = ch, at
		}
	}
	if best == nil {
		return false
	}
	select {
	case best <- liveEvent{kind, raw}:
		return true
	default:
		return false
	}
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
	id := r.URL.Query().Get("client")
	if len(id) > 64 {
		id = ""
	}
	ch := s.events.subscribe(&eventClient{id: id, addr: clientAddr(r)})
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

// checkXPFile announces a new .z/xp_summary*.json (synced from a Neovim).
func (s *Server) checkXPFile() {
	var mod time.Time
	for _, path := range s.xpFiles() {
		if st, err := os.Stat(path); err == nil && st.ModTime().After(mod) {
			mod = st.ModTime()
		}
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
