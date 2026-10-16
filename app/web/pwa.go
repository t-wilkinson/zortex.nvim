package web

// The web app as an installable app (a PWA): a manifest, icons and a
// service worker.
//
//	GET /manifest.webmanifest  name, start URL and scope (with -base), icons
//	GET /sw.js                 the service worker (static/sw.js), served at the
//	                           app's root so its scope is the whole app
//	GET /offline               the page shown when offline and the page asked
//	                           for was never opened: it lists the ones that were
//
// The service worker keeps the static files of this build and the last
// pages you opened, so notes you read recently open without a connection
// (marked as a saved copy). The API, live updates, edits and files are never
// cached. The manifest and icons are served without a login (-auth-file):
// they hold the site's title and nothing from the notes, and a phone's
// installer fetches them without the browser's credentials.

import (
	"encoding/json"
	"net/http"
	"strings"
)

func (s *Server) handleManifest(w http.ResponseWriter, r *http.Request) {
	icon := func(p, size, purpose string) map[string]string {
		return map[string]string{"src": s.assetURL(p), "sizes": size, "type": "image/png", "purpose": purpose}
	}
	short := s.cfg.Title
	if len([]rune(short)) > 12 {
		short = string([]rune(short)[:12])
	}
	m := map[string]any{
		"id":               s.url("/"),
		"name":             s.cfg.Title,
		"short_name":       short,
		"description":      "Notes, calendar and planning from your zortex folder",
		"start_url":        s.url("/"),
		"scope":            s.url("/"),
		"display":          "standalone",
		"background_color": "#f7f5f0",
		"theme_color":      "#1d5f8a",
		"icons": []map[string]string{
			icon("/static/icons/icon-192.png", "192x192", "any"),
			icon("/static/icons/icon-512.png", "512x512", "any"),
			icon("/static/icons/maskable-512.png", "512x512", "maskable"),
		},
		"shortcuts": []map[string]string{
			{"name": "Search", "url": s.url("/search")},
			{"name": "Projects", "url": s.url("/projects")},
		},
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "application/manifest+json")
	_ = json.NewEncoder(w).Encode(m)
}

func (s *Server) handleServiceWorker(w http.ResponseWriter, r *http.Request) {
	raw, err := staticFS.ReadFile("static/sw.js")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	// always fetched fresh: the browser checks it for a new build on each visit
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Write(raw)
}

func (s *Server) handleOffline(w http.ResponseWriter, r *http.Request) {
	s.render(w, r, "offline", http.StatusOK, map[string]any{"Title": "Offline"})
}

// pwaPublic: paths served without a login (see the top of this file).
func (s *Server) pwaPublic(path string) bool {
	return path == "/manifest.webmanifest" || strings.HasPrefix(path, "/static/icons/")
}
