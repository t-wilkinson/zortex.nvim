package web

import (
	"fmt"
	"html"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// GET /api/digest?days=7&site=https://notes.example.com
//
// The coming days of calendar.zortex as a message: {subject, text, html,
// days: [{date, label, entries}]}. Zortex doesn't send email; a cron job
// can pass this to any mail provider, e.g.
//
//	curl -s localhost:8090/api/digest | jq -r .text | mail -s "Agenda" me@example.com
//
// Links in html are absolute: `site`, else the request's own host
// (X-Forwarded-Host / X-Forwarded-Proto behind a proxy).

type digestDay struct {
	Date    string     `json:"date"`
	Label   string     `json:"label"` // "Today, Mon Oct 12"
	Entries []calEntry `json:"entries"`
}

func siteOf(r *http.Request) string {
	if site := strings.TrimRight(r.URL.Query().Get("site"), "/"); site != "" {
		if u, err := url.Parse(site); err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" {
			return u.Scheme + "://" + u.Host
		}
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if p := r.Header.Get("X-Forwarded-Proto"); p == "http" || p == "https" {
		scheme = p
	}
	host := r.Host
	if h := r.Header.Get("X-Forwarded-Host"); h != "" {
		host = strings.TrimSpace(strings.Split(h, ",")[0])
	}
	return scheme + "://" + host
}

func dayLabel(d, today time.Time) string {
	label := d.Format("Mon Jan 2")
	switch d.Format("2006-01-02") {
	case today.Format("2006-01-02"):
		return "Today, " + label
	case today.AddDate(0, 0, 1).Format("2006-01-02"):
		return "Tomorrow, " + label
	}
	return label
}

func (s *Server) apiDigest(w http.ResponseWriter, r *http.Request) {
	days := 7
	if n, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && n >= 1 && n <= 60 {
		days = n
	}
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	last := today.AddDate(0, 0, days-1)
	byDate := s.calendarDays(today.Format("2006-01-02"), last.Format("2006-01-02"))
	site := siteOf(r)

	var (
		out   []digestDay
		text  strings.Builder
		body  strings.Builder
		count int
	)
	for d := today; !d.After(last); d = d.AddDate(0, 0, 1) {
		key := d.Format("2006-01-02")
		entries := byDate[key]
		if len(entries) == 0 {
			continue
		}
		day := digestDay{Date: key, Label: dayLabel(d, today), Entries: entries}
		out = append(out, day)
		fmt.Fprintf(&text, "%s\n", day.Label)
		fmt.Fprintf(&body, `<h3 style="margin:1.2em 0 .3em;font:600 15px sans-serif">%s</h3><ul style="margin:0;padding-left:1.2em;font:14px/1.5 sans-serif">`, html.EscapeString(day.Label))
		for _, e := range entries {
			count++
			when := e.Time
			if e.End != "" {
				when += "–" + e.End
			}
			mark := ""
			switch {
			case e.Done:
				mark = "[x] "
			case e.Moved:
				mark = "[>] "
			case e.Task:
				mark = "[ ] "
			}
			indent := strings.Repeat("  ", e.Depth)
			if when != "" {
				fmt.Fprintf(&text, "  %s%s  %s%s\n", indent, when, mark, e.Text)
			} else {
				fmt.Fprintf(&text, "  %s%s%s\n", indent, mark, e.Text)
			}
			entryHTML := strings.ReplaceAll(e.HTML, `href="/`, `href="`+site+`/`)
			style := ""
			if e.Done {
				style = ` style="color:#777;text-decoration:line-through"`
			}
			fmt.Fprintf(&body, `<li%s>`, style)
			if when != "" {
				fmt.Fprintf(&body, `<a href="%s%s" style="color:inherit;font-variant-numeric:tabular-nums">%s</a> `, html.EscapeString(site), html.EscapeString(e.URL), html.EscapeString(when))
			}
			fmt.Fprintf(&body, "%s%s</li>", html.EscapeString(mark), entryHTML)
		}
		text.WriteString("\n")
		body.WriteString("</ul>")
	}
	span := today.Format("Mon Jan 2")
	if days > 1 {
		span += " – " + last.Format("Mon Jan 2")
	}
	subject := fmt.Sprintf("Agenda: %s (%d entr%s)", span, count, map[bool]string{true: "y", false: "ies"}[count == 1])
	if count == 0 {
		subject = "Agenda: nothing scheduled, " + span
		text.WriteString("Nothing scheduled.\n")
		body.WriteString(`<p style="font:14px sans-serif">Nothing scheduled.</p>`)
	}
	if out == nil {
		out = []digestDay{}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"subject": subject,
		"from":    today.Format("2006-01-02"),
		"to":      last.Format("2006-01-02"),
		"count":   count,
		"text":    strings.TrimRight(text.String(), "\n") + "\n",
		"html":    `<div>` + body.String() + `</div>`,
		"days":    out,
	})
}
