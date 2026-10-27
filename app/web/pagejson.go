package web

import (
	"bytes"
	"encoding/json"
	"html/template"
	"net/http"
	"strings"
	"unicode"
)

// Every page's data as JSON: /api + the page's path, same query
// (/api/projects, /api/review?day=today, /api/f/z/books). The page's
// handler runs as for the page; render() sees the /api/ path and writes
// the data it would have shown, its keys in snake_case, instead of HTML.
// The top bar's and layout's own keys are left out.

// layoutKeys: what render() adds for the layout, not the page's data.
var layoutKeys = map[string]bool{"Site": true, "Base": true, "Nav": true, "NavTab": true, "Query": true, "Menu": true, "NavBroken": true, "SiteWritable": true}

// jsonNames: page keys whose template name is too short for an API.
var jsonNames = map[string]string{"P": "Project"}

// wantsJSON: a request for a page's data (/api/projects) rather than the page.
func wantsJSON(r *http.Request) bool {
	return r != nil && strings.HasPrefix(r.URL.Path, "/api/")
}

// pageJSON writes a page's data as JSON: an error page as {"error"}.
func (s *Server) pageJSON(w http.ResponseWriter, page string, status int, data map[string]any) {
	if page == "error" {
		msg, _ := data["Message"].(string)
		if msg == "" {
			msg, _ = data["Title"].(string)
		}
		writeJSON(w, status, map[string]any{"error": msg})
		return
	}
	out := map[string]any{}
	for k, v := range data {
		if !layoutKeys[k] {
			if name, ok := jsonNames[k]; ok {
				k = name
			}
			out[k] = v
		}
	}
	raw, err := json.Marshal(out)
	if err != nil {
		s.log.Printf("json %s: %v", page, err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "can't encode " + page + ": " + err.Error()})
		return
	}
	var v any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, status, snakeKeys(v))
}

// snakeKeys renames every object key of a decoded JSON value to snake_case.
func snakeKeys(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[snake(k)] = snakeKeys(val)
		}
		return out
	case []any:
		for i := range x {
			x[i] = snakeKeys(x[i])
		}
		return x
	}
	return v
}

// snake: "DoneDate" -> "done_date", "XPHours" -> "xp_hours", "URL" -> "url",
// "KRs" -> "krs", "already_snake" unchanged.
func snake(s string) string {
	rs := []rune(s)
	var b strings.Builder
	for i, r := range rs {
		if unicode.IsUpper(r) {
			prevLower := i > 0 && (unicode.IsLower(rs[i-1]) || unicode.IsDigit(rs[i-1]))
			// the end of an acronym before a word: "XPHours" -> "xp_hours";
			// not an acronym's plural: "KRs"
			nextLower := i+1 < len(rs) && unicode.IsLower(rs[i+1]) &&
				!(rs[i+1] == 's' && (i+2 == len(rs) || unicode.IsUpper(rs[i+2])))
			startsWord := i > 0 && unicode.IsUpper(rs[i-1]) && nextLower
			if prevLower || startsWord {
				b.WriteByte('_')
			}
			b.WriteRune(unicode.ToLower(r))
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// The page data's tree types, as JSON: what an API reader needs, without
// the links back up the tree (Parent) that would never end.

// MarshalJSON: a project, without its parent, its tasks or its sub-projects'
// subtrees (their names and lines are listed).
func (p *webProject) MarshalJSON() ([]byte, error) {
	type child struct {
		Name string `json:"name"`
		Rel  string `json:"rel"`
		Lnum int    `json:"lnum"`
	}
	var kids []child
	for _, c := range p.Children {
		kids = append(kids, child{c.Name, c.Rel, c.Lnum})
	}
	ru := p.rollup()
	return json.Marshal(map[string]any{
		"name": p.Name, "link": p.Link, "rel": p.Rel, "lnum": p.Lnum, "path": p.Path, "root": p.Root,
		"size": p.Size, "p": p.P, "i": p.I, "due": p.Due, "done": p.Done, "areas": p.Areas,
		"progress": map[string]any{"total": ru.Total, "done": ru.DoneN, "open": ru.Open, "hours": ru.Hours, "done_hours": ru.DoneHours, "percent": ru.Percent()},
		"children": kids,
	})
}

// MarshalJSON: a project in a list, its progress and next task.
func (r projectRow) MarshalJSON() ([]byte, error) {
	return json.Marshal(map[string]any{"project": r.P, "url": r.URL, "focus": r.Focus, "key_results": r.KRs, "next": r.Next, "context": r.Context})
}

// MarshalJSON: an area and its sub-areas, without its parent.
func (a *webArea) MarshalJSON() ([]byte, error) {
	type out struct {
		Key        string          `json:"key"`
		Name       string          `json:"name"`
		Value      string          `json:"value"`
		Depth      int             `json:"depth"`
		Rel        string          `json:"rel"`
		Lnum       int             `json:"lnum"`
		URL        string          `json:"url"`
		Vision     string          `json:"vision,omitempty"`
		Default    bool            `json:"default,omitempty"`
		XP         float64         `json:"xp"`
		TotalXP    float64         `json:"total_xp"`
		Level      int             `json:"level,omitempty"`
		Progress   float64         `json:"progress"`
		Objectives []*webObjective `json:"objectives"`
		Projects   []projectRow    `json:"projects"`
		Done       int             `json:"done_projects"`
		Children   []*webArea      `json:"children"`
	}
	return json.Marshal(out{a.Key, a.Name, a.Value, a.Depth, a.Rel, a.Lnum, a.URL, a.Vision, a.Default, a.XP, a.TotalXP, a.Level, a.Progress, a.Objectives, a.Projects, a.Done, a.Children})
}

// MarshalJSON: a key result with the projects it links (by name and line).
func (k webKR) MarshalJSON() ([]byte, error) {
	type proj struct {
		Name string `json:"name"`
		Rel  string `json:"rel"`
		Lnum int    `json:"lnum"`
	}
	var ps []proj
	for _, p := range k.Projects {
		ps = append(ps, proj{p.Name, p.Rel, p.Lnum})
	}
	return json.Marshal(map[string]any{"id": k.ID, "text": k.Text, "html": template.HTML(k.HTML), "done": k.Done, "has_box": k.HasBox,
		"objective": k.Objective, "progress": k.Progress, "lag": k.Lag, "stuck": k.Stuck(), "url": k.URL, "projects": ps})
}

// MarshalJSON: a key result on /okr, with its projects' rows (the embedded
// webKR's own MarshalJSON would leave them out).
func (k okrKR) MarshalJSON() ([]byte, error) {
	raw, err := k.webKR.MarshalJSON()
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	m["rows"] = k.Rows
	return json.Marshal(m)
}
