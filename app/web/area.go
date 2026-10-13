package web

import (
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/links"
)

// Header attributes such as "@area(3.2)" or "@a(1.2/Fitness)" sit in the
// header like tags, so they show up in the tag index. Their tag page links to
// the area they name rather than to a tag search.

// areaDefinitions turns an area attribute value into link definitions, as
// the plugin's area parser (utils/attributes.lua) does:
//
//	"3.2"          -> "Areas/#3.2"
//	"1.2/Fitness"  -> "Areas/#1.2/:Fitness"
//	"a/b/c"        -> "Areas/a/b/c" (three or more components: unchanged)
//
// Values are comma-separated.
func areaDefinitions(value string) []string {
	var defs []string
	for _, v := range strings.Split(value, ",") {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		var comps []string
		for _, c := range strings.Split(v, "/") {
			if c = strings.TrimSpace(c); c != "" {
				comps = append(comps, c)
			}
		}
		if len(comps) == 0 {
			continue
		}
		if len(comps) > 2 {
			defs = append(defs, "Areas/"+v)
			continue
		}
		if !strings.HasPrefix(comps[0], "#") {
			comps[0] = "#" + comps[0]
		}
		if len(comps) == 2 && !strings.HasPrefix(comps[1], ":") {
			comps[1] = ":" + comps[1]
		}
		defs = append(defs, "Areas/"+strings.Join(comps, "/"))
	}
	return defs
}

// attributeTag splits "name(value)" header tags: ("area", "3.2", true).
func attributeTag(tag string) (name, value string, ok bool) {
	open := strings.IndexByte(tag, '(')
	if open < 1 || !strings.HasSuffix(tag, ")") {
		return "", "", false
	}
	name = tag[:open]
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return "", "", false
		}
	}
	return strings.ToLower(name), tag[open+1 : len(tag)-1], true
}

// tagTarget is a link a tag page offers: "Resolve [@Tag]" for a tag, the
// area for an area attribute.
type tagTarget struct {
	Def   string // link definition for /link?to=
	Label string // what the link reads, e.g. "[A/#3.2]"
	Title string // where it lands, when it resolves: "3.2 Fitness"
}

func (s *Server) tagTargets(tag string) []tagTarget {
	name, value, ok := attributeTag(tag)
	if !ok {
		return []tagTarget{{Def: "@" + tag, Label: "Resolve [@" + tag + "]"}}
	}
	if name != "a" && name != "area" {
		return nil // another attribute: there is nothing to resolve
	}
	var out []tagTarget
	for _, def := range areaDefinitions(value) {
		t := tagTarget{Def: def, Label: "[A/" + strings.TrimPrefix(def, "Areas/") + "]"}
		if r, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{}); err == nil && r != nil {
			if n := r.Doc.NodeAt(r.Lnum); n != nil && !n.IsRoot() {
				t.Title = n.Breadcrumb(" › ")
			}
		}
		out = append(out, t)
	}
	return out
}
