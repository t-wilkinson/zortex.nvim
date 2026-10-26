package web

import (
	"encoding/json"
	"math"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Areas on the web, read the way the plugin reads them
// (lua/zortex/services/areas): the headings, bold headings and labels of
// areas.zortex, nested ("Vision:" is not an area, it says what one is for).
//
//	GET /areas   every area: its vision, its area XP (Mastery: own, with its
//	             sub-areas', its level), the objectives that name it now and
//	             the projects that carry it; the area XP of all of them
//	             together at the top
//
// XP comes from the summary Neovim publishes (area_tree, area_total); the
// structure, objectives and projects are read here.

// webArea is an area: a section of the Areas note.
type webArea struct {
	Key      string // "Areas/1 Personal/1.1 Health", as Neovim keys its XP
	Name     string
	Value    string // the @area(…) value that names it: "1.1", "1.2/Fitness"
	Depth    int    // 1 for a top-level area
	Rel      string
	Lnum     int
	URL      string
	Parent   *webArea
	Children []*webArea
	Vision   string
	Default  bool // the default area (xp.default_area): where work without one earns
	node     *notes.Node

	// from the XP summary
	HasXP    bool
	XP       float64 // its own
	TotalXP  float64 // with its sub-areas' (xp.area.bubble)
	Level    int
	Progress float64 // to the next level, 0..1
	ToNext   float64
	Hours    float64 // TotalXP as hours of estimated work

	Objectives []*webObjective // current ones that name it
	Projects   []projectRow    // active projects that carry it (their own @a or a parent's)
	Done       int             // its projects marked done
}

func (a *webArea) ProgressPercent() int { return int(math.Round(a.Progress * 100)) }

// Subtree: it has sub-areas with XP of their own (its total is more than its own).
func (a *webArea) Subtree() bool { return a.XP >= 0.5 && math.Round(a.TotalXP) != math.Round(a.XP) }

func (a *webArea) walk(fn func(*webArea)) {
	fn(a)
	for _, c := range a.Children {
		c.walk(fn)
	}
}

// areasDoc: areas.zortex, or the note named Areas (or A).
func (s *Server) areasDoc() *notes.Document {
	if d := s.ix.Doc("areas" + s.cfg.Ext); d != nil {
		return d
	}
	for _, name := range []string{"Areas", "A"} {
		for _, rel := range s.ix.Catalog().WithName(name) {
			if d := s.ix.Doc(rel); d != nil && !s.ix.IsArchived(rel) {
				return d
			}
		}
	}
	return nil
}

var (
	visionRe    = regexp.MustCompile(`^\s*[Vv]ision:\s*(.*?)\s*$`)
	areaNumRe   = regexp.MustCompile(`^(\d[\d.]*)(?:\s|$)`)
	listMarkRe  = regexp.MustCompile(`^\s*[-*]\s+`)
	labelLineRe = regexp.MustCompile(`^\S.*:\s*$`)
)

func isAreaNode(n *notes.Node) bool {
	switch n.Type {
	case syntax.KindHeading, syntax.KindBoldHeading:
		return true
	case syntax.KindLabel:
		return !strings.EqualFold(n.Text, "vision")
	}
	return false
}

// visionIn: the text of a "Vision:" line in lines[from..to] (1-based), or
// on the lines under it up to a blank line, a heading or another label
// (services/areas/area.lua vision()).
func visionIn(lines []string, from, to int) string {
	for l := from; l <= to && l <= len(lines); l++ {
		m := visionRe.FindStringSubmatch(lines[l-1])
		if m == nil {
			continue
		}
		if m[1] != "" {
			return m[1]
		}
		var parts []string
		for k := l + 1; k <= len(lines); k++ {
			t := lines[k-1]
			if strings.TrimSpace(t) == "" || strings.HasPrefix(t, "#") || labelLineRe.MatchString(t) {
				break
			}
			parts = append(parts, strings.TrimSpace(listMarkRe.ReplaceAllString(t, "")))
		}
		return strings.Join(parts, " ")
	}
	return ""
}

// areaValue: the short @area(…) value of an area (services/areas value()).
func areaValue(a *webArea) string {
	short := func(x *webArea) string {
		if m := areaNumRe.FindStringSubmatch(x.Name); m != nil {
			return m[1]
		}
		return x.Name
	}
	if a.node == nil || a.node.Type != syntax.KindLabel || a.Parent == nil {
		return short(a)
	}
	head := a.Parent
	for head.Parent != nil && head.node != nil && head.node.Type == syntax.KindLabel {
		head = head.Parent
	}
	return short(head) + "/" + a.Name
}

// areaTree: the areas of the Areas note (top-level ones) and the vision
// written above them; byLine finds an area by the line its section starts on.
func (s *Server) areaTree() (roots []*webArea, vision string, byLine map[int]*webArea, d *notes.Document) {
	d = s.areasDoc()
	byLine = map[int]*webArea{}
	if d == nil {
		return nil, "", byLine, nil
	}
	name := d.Name()
	if name == "" {
		name = "Areas"
	}
	var visit func(n *notes.Node, parent *webArea, path []string, depth int)
	visit = func(n *notes.Node, parent *webArea, path []string, depth int) {
		for _, c := range n.Children {
			if !isAreaNode(c) {
				continue
			}
			here := append(append([]string(nil), path...), c.Text)
			a := &webArea{Key: name + "/" + strings.Join(here, "/"), Name: c.Text, Depth: depth, Rel: d.Rel, Lnum: c.Start, URL: s.noteURL(d.Rel, c.Start), Parent: parent, node: c}
			// its own lines: up to its first sub-area
			own := c.End
			for _, k := range c.Children {
				if isAreaNode(k) {
					own = k.Start - 1
					break
				}
			}
			a.Vision = visionIn(d.Lines, c.Start, own)
			a.Value = areaValue(a)
			byLine[c.Start] = a
			if parent == nil {
				roots = append(roots, a)
			} else {
				parent.Children = append(parent.Children, a)
			}
			visit(c, a, here, depth+1)
		}
	}
	for _, n := range d.Tree.Children {
		if n.Type == syntax.KindArticle {
			// the vision above every area
			first := n.End
			for _, c := range n.Children {
				if isAreaNode(c) {
					first = c.Start - 1
					break
				}
			}
			vision = visionIn(d.Lines, n.Start, first)
			visit(n, nil, nil, 1)
		} else if isAreaNode(n) {
			visit(&notes.Node{Children: []*notes.Node{n}}, nil, nil, 1)
		}
	}
	return roots, vision, byLine, d
}

// resolveArea: the area an @area(…) value names, or nil.
func (s *Server) resolveArea(value string, byLine map[int]*webArea, d *notes.Document) *webArea {
	if d == nil {
		return nil
	}
	for _, def := range areaDefinitions(value) {
		res, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{})
		if err != nil || res == nil || res.Doc == nil || res.Doc.Rel != d.Rel {
			continue
		}
		if a := byLine[res.Lnum]; a != nil {
			return a
		}
	}
	return nil
}

// summaryArea is an area of the XP summary (area_tree; older summaries only
// have the top areas).
type summaryArea struct {
	Key      string  `json:"key"`
	XP       float64 `json:"xp"`
	TotalXP  float64 `json:"total_xp"`
	Level    int     `json:"level"`
	Progress float64 `json:"progress"`
	ToNext   float64 `json:"xp_to_next"`
	Rel      string  `json:"rel"`
	Lnum     int     `json:"lnum"`
	Default  bool    `json:"default"`
}

type areaSummary struct {
	Tree        []summaryArea `json:"area_tree"`
	Top         []summaryArea `json:"areas"`
	Total       *float64      `json:"area_total"`
	Calibration *struct {
		XPPerHour   float64 `json:"xp_per_hour"`
		DefaultArea *string `json:"default_area"`
	} `json:"calibration"`
	Generated time.Time `json:"generated"`
}

func (s *Server) areaSummary() (areaSummary, bool) {
	var sum areaSummary
	raw := s.xpSummary()
	if raw == nil || s.cfg.NoXP {
		return sum, false
	}
	if json.Unmarshal(raw, &sum) != nil {
		return sum, false
	}
	return sum, true
}

// defaultAreaValue: the @area(…) value work without one earns for (the
// summary's calibration, Neovim's xp.default_area), "" when it is off.
func (s *Server) defaultAreaValue() string {
	sum, ok := s.areaSummary()
	if ok && sum.Calibration != nil && sum.Calibration.DefaultArea != nil {
		return *sum.Calibration.DefaultArea
	}
	return "0.1"
}

func (s *Server) handleAreas(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	roots, vision, byLine, d := s.areaTree()
	all := s.allProjects()
	krs := s.keyResults(all, now)
	_, focus, _ := s.focus(all, now)
	focused := map[*webProject]bool{}
	for _, p := range focus {
		focused[p] = true
	}

	// XP from Neovim's summary, by key (else by line)
	sum, hasXP := s.areaSummary()
	byKey := map[string]summaryArea{}
	for _, x := range sum.Tree {
		byKey[x.Key] = x
	}
	if len(sum.Tree) == 0 {
		for _, x := range sum.Top {
			x.TotalXP = x.XP // the top areas' xp is with their sub-areas'
			byKey[x.Key] = x
		}
	}
	byPos := map[int]summaryArea{}
	for _, x := range sum.Tree {
		if d != nil && x.Rel == d.Rel {
			byPos[x.Lnum] = x
		}
	}
	total, count, maxLevel := 0.0, 0, 0
	for _, root := range roots {
		root.walk(func(a *webArea) {
			count++
			x, ok := byKey[a.Key]
			if !ok {
				x, ok = byPos[a.Lnum]
			}
			if ok {
				a.HasXP = true
				a.XP, a.TotalXP, a.Level, a.Progress, a.ToNext, a.Default = x.XP, x.TotalXP, x.Level, x.Progress, x.ToNext, x.Default
				total += x.XP
				if x.Level > maxLevel {
					maxLevel = x.Level
				}
			}
		})
	}
	if sum.Total != nil {
		total = *sum.Total
	}
	if def := s.defaultAreaValue(); def != "" {
		if a := s.resolveArea(def, byLine, d); a != nil {
			a.Default = true
		}
	}

	// projects that carry an area: their own @a, else the nearest parent's
	for _, p := range all {
		if p.Root {
			continue
		}
		var values []string
		for _, x := range p.lineage() {
			if len(x.Areas) > 0 {
				values = x.Areas
				break
			}
		}
		seen := map[*webArea]bool{}
		for _, v := range values {
			for _, part := range strings.Split(v, ",") {
				a := s.resolveArea(strings.TrimSpace(part), byLine, d)
				if a == nil || seen[a] {
					continue
				}
				seen[a] = true
				if p.isDone() {
					a.Done++
					continue
				}
				if ru := p.rollup(); ru.Open > 0 {
					a.Projects = append(a.Projects, s.row(p, focused, krs))
				}
			}
		}
	}
	// objectives running now that name it
	today := now.Format("2006-01-02")
	for _, o := range s.objectives(all, now) {
		if o.Done != "" || o.Start.Format("2006-01-02") > today || o.End.Format("2006-01-02") < today {
			continue
		}
		seen := map[*webArea]bool{}
		for _, v := range o.Areas {
			if a := s.resolveArea(v, byLine, d); a != nil && !seen[a] {
				seen[a] = true
				a.Objectives = append(a.Objectives, o)
			}
		}
	}

	xph := 10.0
	if sum.Calibration != nil && sum.Calibration.XPPerHour > 0 {
		xph = sum.Calibration.XPPerHour
	}
	for _, root := range roots {
		root.walk(func(a *webArea) { a.Hours = a.TotalXP / xph })
	}
	s.render(w, r, "areas", http.StatusOK, map[string]any{
		"Title":     "Areas",
		"Roots":     roots,
		"Vision":    vision,
		"HasAreas":  d != nil,
		"AreasURL":  s.areasNoteURL(d),
		"HasXP":     hasXP,
		"Total":     math.Round(total),
		"Hours":     total / xph,
		"XPPerHour": xph,
		"Count":     count,
		"MaxLevel":  maxLevel,
		"Generated": sum.Generated,
		"Default":   s.defaultAreaValue(),
	})
}

func (s *Server) areasNoteURL(d *notes.Document) string {
	if d == nil {
		return ""
	}
	return s.noteURL(d.Rel, 0)
}
