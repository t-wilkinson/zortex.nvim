package web

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Opening a page from Neovim in a tab that is already open, instead of a new
// one (features/web in the plugin). A browser doesn't let anything outside
// it pick a tab, but every page already listens on /api/events:
//
//	POST /api/presence  {"client": id}           a page was focused
//	POST /api/open      {"path": "/n/x#L3"}      Neovim: show this
//	POST /api/open/ack  {"token": t}             the page got it
//
// /api/open sends the path to the page on the same device (the same client
// address) that was focused most recently, and answers {"opened": true}
// once that page acknowledges, within openWait. Otherwise {"opened": false}
// and Neovim opens a new tab. A page can show the path but can't bring its
// window to the front.

const openWait = 2 * time.Second

type openWaits struct {
	mu sync.Mutex
	m  map[string]chan struct{}
}

func (o *openWaits) add(token string) chan struct{} {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.m == nil {
		o.m = map[string]chan struct{}{}
	}
	ch := make(chan struct{})
	o.m[token] = ch
	return ch
}

func (o *openWaits) done(token string) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	ch, ok := o.m[token]
	if ok {
		close(ch)
		delete(o.m, token)
	}
	return ok
}

func (o *openWaits) drop(token string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	delete(o.m, token)
}

// clientAddr is the address a request comes from: the first
// X-Forwarded-For (or X-Real-IP) hop when a proxy on this machine or the
// local network passed it on, else the connection's.
func clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip := net.ParseIP(host); ip != nil && (ip.IsLoopback() || ip.IsPrivate()) {
		if f := r.Header.Get("X-Forwarded-For"); f != "" {
			first, _, _ := strings.Cut(f, ",")
			if p := strings.TrimSpace(first); p != "" {
				return p
			}
		}
		if p := strings.TrimSpace(r.Header.Get("X-Real-IP")); p != "" {
			return p
		}
	}
	return host
}

// appPath: a path in this app ("/n/x.zortex#L3"), not another site's.
func appPath(p string) bool {
	return len(p) < 8192 && strings.HasPrefix(p, "/") && !strings.HasPrefix(p, "//") && !strings.HasPrefix(p, "/\\") &&
		!strings.ContainsAny(p, "\r\n")
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad JSON: " + err.Error()})
		return false
	}
	return true
}

func (s *Server) apiPresence(w http.ResponseWriter, r *http.Request) {
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json)"})
		return
	}
	var req struct {
		Client string `json:"client"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	s.events.focus(req.Client)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) apiOpen(w http.ResponseWriter, r *http.Request) {
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json) or X-API-Key"})
		return
	}
	var req struct {
		Path string `json:"path"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !appPath(req.Path) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "path must be a path in this app, like /n/note.zortex"})
		return
	}
	var b [12]byte
	_, _ = rand.Read(b[:])
	token := hex.EncodeToString(b[:])
	acked := s.opens.add(token)
	defer s.opens.drop(token)
	if !s.events.sendToLatest(clientAddr(r), "open", map[string]string{"path": req.Path, "token": token}) {
		writeJSON(w, http.StatusOK, map[string]any{"opened": false, "reason": "no open tab on this device"})
		return
	}
	t := time.NewTimer(openWait)
	defer t.Stop()
	select {
	case <-acked:
		writeJSON(w, http.StatusOK, map[string]any{"opened": true})
	case <-t.C:
		writeJSON(w, http.StatusOK, map[string]any{"opened": false, "reason": "the tab didn't answer"})
	case <-r.Context().Done():
	}
}

func (s *Server) apiOpenAck(w http.ResponseWriter, r *http.Request) {
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json)"})
		return
	}
	var req struct {
		Token string `json:"token"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !s.opens.done(req.Token) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such request"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
