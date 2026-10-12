package web

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// XP lives in Neovim (lua/zortex/services/xp/ledger: it is read off the
// notes there). After every change Neovim publishes a small summary, both
// into the synced notes folder (.z/xp_summary.json) and, when it talks to
// this server, as POST /api/xp. The home page shows the newer of the two.
//
//	GET  /api/xp   the summary, or {"available": false}
//	POST /api/xp   store a summary (X-API-Key when -api-key is set)

const xpFile = "xp_summary.json"

type xpCache struct {
	mu     sync.Mutex
	posted []byte // last POSTed summary (also in DataDir)
	// the notes folder's copy, re-read when its mtime changes
	fileMod  time.Time
	fileBody []byte
}

// generated reads the summary's "generated" time (zero when missing).
func generated(raw []byte) time.Time {
	var head struct {
		Generated time.Time `json:"generated"`
	}
	if json.Unmarshal(raw, &head) != nil {
		return time.Time{}
	}
	return head.Generated
}

func (s *Server) xpSummary() []byte {
	c := &s.xp
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.posted == nil && s.cfg.DataDir != "" {
		if raw, err := os.ReadFile(filepath.Join(s.cfg.DataDir, xpFile)); err == nil {
			c.posted = raw
		}
	}
	path := filepath.Join(s.cfg.Root, ".z", xpFile)
	if st, err := os.Stat(path); err == nil {
		if !st.ModTime().Equal(c.fileMod) {
			if raw, err := os.ReadFile(path); err == nil && json.Valid(raw) {
				c.fileBody, c.fileMod = raw, st.ModTime()
			}
		}
	} else {
		c.fileBody, c.fileMod = nil, time.Time{}
	}
	switch {
	case c.posted == nil:
		return c.fileBody
	case c.fileBody == nil:
		return c.posted
	case generated(c.fileBody).After(generated(c.posted)):
		return c.fileBody
	}
	return c.posted
}

func (s *Server) apiXP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	raw := s.xpSummary()
	if raw == nil {
		writeJSON(w, http.StatusOK, map[string]any{"available": false})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(raw)
}

func (s *Server) apiXPPost(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"success": false, "error": "bad API key"})
		return
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"success": false, "error": "send JSON"})
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"success": false, "error": err.Error()})
		return
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "error": "invalid JSON: " + err.Error()})
		return
	}
	if _, ok := obj["generated"]; !ok {
		// stamp it so the newest copy wins
		obj["generated"], _ = json.Marshal(time.Now().UTC())
	}
	obj["available"] = json.RawMessage("true")
	var buf bytes.Buffer
	_ = json.NewEncoder(&buf).Encode(obj)
	body := bytes.TrimSpace(buf.Bytes())
	s.xp.mu.Lock()
	s.xp.posted = body
	s.xp.mu.Unlock()
	if s.cfg.DataDir != "" {
		path := filepath.Join(s.cfg.DataDir, xpFile)
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, body, 0o640); err == nil {
			_ = os.Rename(tmp, path)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}
