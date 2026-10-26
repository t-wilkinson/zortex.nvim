package web

import (
	"encoding/json"
	"net/http"
	"sync"
)

// The attribute help (GET /attributes): what each @attribute means and how
// it is written, for writing notes on a phone. The table is the plugin's
// (lua/zortex/attributes_help.lua), written to static/attributes.json by
// tests/gen_docs.lua; the editor and the inbox box link here.

type attrHelp struct {
	Key     string   `json:"key"`
	Group   string   `json:"group"`
	Short   []string `json:"short"`
	Insert  string   `json:"insert"`
	Formats []string `json:"formats"`
	Where   string   `json:"where"`
	Desc    string   `json:"desc"`
}

type attrGroup struct {
	ID    string     `json:"id"`
	Title string     `json:"title"`
	List  []attrHelp `json:"-"`
}

var attrHelpOnce = sync.OnceValues(func() ([]attrGroup, error) {
	raw, err := staticFS.ReadFile("static/attributes.json")
	if err != nil {
		return nil, err
	}
	var data struct {
		Groups     []attrGroup `json:"groups"`
		Attributes []attrHelp  `json:"attributes"`
	}
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, err
	}
	for i := range data.Groups {
		for _, a := range data.Attributes {
			if a.Group == data.Groups[i].ID {
				data.Groups[i].List = append(data.Groups[i].List, a)
			}
		}
	}
	return data.Groups, nil
})

func (s *Server) handleAttributes(w http.ResponseWriter, r *http.Request) {
	groups, err := attrHelpOnce()
	if err != nil {
		s.log.Printf("attributes: %v", err)
	}
	s.render(w, r, "attributes", http.StatusOK, map[string]any{
		"Title":  "Attributes",
		"Groups": groups,
	})
}
