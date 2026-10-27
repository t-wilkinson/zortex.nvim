package web

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode"
)

// Every page's data is JSON at /api + its path: snake_case keys, no layout.
func TestPagesAsJSON(t *testing.T) {
	_, _, ts := writableServer(t)
	var walk func(path string, v any)
	walk = func(path string, v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, val := range x {
				if k == "" || unicode.IsUpper(rune(k[0])) || strings.ContainsAny(k, " -") {
					t.Errorf("%s: key %q isn't snake_case", path, k)
				}
				walk(path, val)
			}
		case []any:
			for _, val := range x {
				walk(path, val)
			}
		}
	}
	for path, keys := range map[string][]string{
		"/api/projects": {"active", "focus", "quiet"},
		"/api/project?rel=projects.zortex&lnum=14": {"project", "open", "closed", "children"},
		"/api/okr":                   {"periods", "has_okr"},
		"/api/areas":                 {"roots", "has_areas"},
		"/api/review":                {"week", "inbox", "completed"},
		"/api/review?day=2026-10-08": {"date", "unassigned", "open"},
		"/api/broken":                {"broken", "orphans"},
		"/api/tags":                  {"tags"},
		"/api/f/z":                   {"entries", "rel"},
		"/api/attributes":            {"groups"},
	} {
		code, h, body := get(t, ts, path)
		if code != 200 || !strings.HasPrefix(h.Get("Content-Type"), "application/json") {
			t.Errorf("%s: %d %s", path, code, h.Get("Content-Type"))
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(body), &m); err != nil {
			t.Errorf("%s: %v", path, err)
			continue
		}
		for _, k := range keys {
			if _, ok := m[k]; !ok {
				t.Errorf("%s: no %q in %v", path, k, keysOf(m))
			}
		}
		for _, k := range []string{"site", "nav", "menu", "base"} {
			if _, ok := m[k]; ok {
				t.Errorf("%s: layout key %q", path, k)
			}
		}
		walk(path, m)
	}
	// a note's JSON; a note under /api/f/ goes there; a missing page is {"error"}
	expect(t, ts, "/api/n/projects.zortex", 200, `"rel":"projects.zortex"`, `"title":"Projects"`, `"body":`)
	if code, h, _ := get(t, ts, "/api/f/projects.zortex"); code != 302 || h.Get("Location") != "/api/n/projects.zortex" {
		t.Errorf("/api/f/ on a note: %d %s", code, h.Get("Location"))
	}
	expect(t, ts, "/api/project?rel=nope.zortex&lnum=1", 404, `"error"`)
	expect(t, ts, "/api/link?to=%5BP%2F%231.4%20-%20zortex%5D", 200)
	expect(t, ts, "/api/graph", 200, `"sources"`)
}

func keysOf(m map[string]any) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestSnake(t *testing.T) {
	for in, want := range map[string]string{"DoneDate": "done_date", "XPHours": "xp_hours", "URL": "url", "PURL": "purl", "KRs": "krs", "HasOKR": "has_okr", "already_snake": "already_snake", "Lnum": "lnum", "ID": "id", "AreaLinks": "area_links", "SpentTotal": "spent_total", "OwnEnd": "own_end", "DoneN": "done_n"} {
		if got := snake(in); got != want {
			t.Errorf("snake(%q) = %q, want %q", in, got, want)
		}
	}
}
