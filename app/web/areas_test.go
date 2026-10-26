package web

import (
	"strings"
	"testing"
	"time"
)

// /areas: the area tree from areas.zortex, its XP from Neovim's summary,
// the objectives and projects of each area.
func TestAreasPage(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	page := expect(t, ts, "/areas", 200, `<h1>Areas</h1>`, `aria-current="page">Areas`, `1 Personal Foundation`, `1.2 Vitality`, `Fitness`,
		`4.1 Education &amp; Skills`, `1.4 - zortex`)
	if strings.Contains(page, `Area XP</span>`) {
		t.Error("no XP tile before Neovim publishes a summary")
	}
	postJSON(t, ts.URL, "/api/xp", map[string]any{
		"version": 3, "generated": time.Now().UTC().Format(time.RFC3339),
		"calibration": map[string]any{"xp_per_hour": 10, "default_area": "0.1"},
		"area_total":  120,
		"area_tree": []map[string]any{
			{"key": "Areas/4 Learning & Education", "xp": 20, "total_xp": 95, "level": 1, "progress": 0.3},
			{"key": "Areas/4 Learning & Education/4.1 Education & Skills", "xp": 100, "total_xp": 100, "level": 1, "progress": 0.5},
		},
	})
	page = expect(t, ts, "/areas", 200, `Area XP</span>`, `>120<`, `12h of work, all areas`, `100 XP · 10h`, `95 XP · 9h30m`, `(20 own)`)
	// the fixture's objectives are Q1's: none running now
	if strings.Contains(page, `Ship zortex projects`) || !strings.Contains(page, `No objective this period and no active project`) {
		t.Error("only the objectives running now; areas with nothing say so")
	}
	if strings.Count(page, `class="pill tier">Lvl 1`) != 2 {
		t.Error("levels of the areas with XP")
	}
}

func TestAttributesPage(t *testing.T) {
	_, _, ts := newTestServer(t, "")
	expect(t, ts, "/attributes", 200, `<h1>Attributes</h1>`, `@due(2026-10-20)`, `@a(1.2/Fitness)`, `@project(1.4)`, `@notify(15)`, `Planning: tasks, projects, objectives`)
	expect(t, ts, "/static/attributes.json", 200, `"key": "due"`)
}
