package syntax

import "encoding/json"

// JSON output matches the Lua parser's (core/syntax) table layout exactly:
// the same keys, present only when the Lua table has them.

// MarshalJSON emits the line descriptor with the Lua parser's keys.
func (l *Line) MarshalJSON() ([]byte, error) {
	m := map[string]any{"kind": l.Kind, "indent": l.Indent}
	if l.ContentCol != nil {
		m["content_col"] = *l.ContentCol
	}
	if l.ContentEnd != nil {
		m["content_end"] = *l.ContentEnd
	}
	if l.Section {
		m["section"] = true
	}
	if l.Level != nil {
		m["level"] = *l.Level
	}
	if l.Heading != 0 {
		m["heading"] = l.Heading
	}
	if l.Text != nil {
		m["text"] = *l.Text
	}
	if l.Names != nil {
		m["names"] = l.Names
	}
	if l.Item != nil {
		m["item"] = l.Item
	}
	if l.Key != "" {
		m["key"] = l.Key
	}
	if l.KeyCol != nil {
		m["key_col"] = *l.KeyCol
	}
	if l.KeyLen != 0 {
		m["key_len"] = l.KeyLen
	}
	if l.ID != "" {
		m["id"] = l.ID
	}
	if l.Separator != nil {
		m["separator"] = *l.Separator
	}
	if l.Close {
		m["close"] = true
	}
	if l.Lang != nil {
		m["lang"] = *l.Lang
	}
	if l.Inline != nil {
		m["inline"] = l.Inline
	}
	return json.Marshal(m)
}

// MarshalJSON emits the span with the keys its type has in the Lua parser.
func (s Span) MarshalJSON() ([]byte, error) {
	m := map[string]any{"type": s.Type, "s": s.S, "e": s.E}
	switch s.Type {
	case "link", "live_link":
		m["definition"] = s.Definition
	case "tag_search":
		m["content"], m["terms"], m["query_type"] = s.Content, s.Terms, s.QueryType
	case "markdown":
		m["text"], m["url"] = s.Text, s.URL
	case "footnote_ref":
		m["id"] = s.ID
	case "url":
		m["url"] = s.URL
	case "filepath":
		m["path"] = s.Path
	case "attribute":
		m["key"] = s.Key
		if s.HasValue {
			m["value"] = s.Value
		}
	case "code":
		m["inner_s"], m["inner_e"] = s.InnerS, s.InnerE
	case "math":
		m["inner_s"], m["inner_e"], m["display"] = s.InnerS, s.InnerE, s.Display
	case "bold", "italic":
		children := s.Children
		if children == nil {
			children = []Span{}
		}
		m["inner_s"], m["inner_e"], m["children"] = s.InnerS, s.InnerE, children
	case "time":
		m["value"] = s.Value
	}
	return json.Marshal(m)
}
