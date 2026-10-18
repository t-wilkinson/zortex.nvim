package ical

import (
	"fmt"
	"io"
	"strings"
	"time"
)

// Out is an event to write: a timed one (Start, End) or an all-day one
// (AllDay; Start is the day, End the day after the last).
type Out struct {
	UID         string
	Summary     string
	Description string
	URL         string
	Start, End  time.Time
	AllDay      bool
}

// escape a TEXT value
func escape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, ";", `\;`, ",", `\,`, "\r\n", `\n`, "\n", `\n`)
	return r.Replace(s)
}

// fold a content line at 75 octets (RFC 5545 3.1), not inside a UTF-8 rune
func fold(line string) string {
	if len(line) <= 75 {
		return line
	}
	var b strings.Builder
	n := 0
	for i, r := range line {
		size := len(string(r))
		if n+size > 75 {
			b.WriteString("\r\n ")
			n = 1
		}
		b.WriteString(line[i : i+size])
		n += size
	}
	return b.String()
}

// Write writes a calendar named `name` with the events. Times are written in
// UTC, all-day events as dates. `stamp` is the DTSTAMP of every event.
func Write(w io.Writer, name string, events []Out, stamp time.Time) error {
	var b strings.Builder
	line := func(s string) {
		b.WriteString(fold(s))
		b.WriteString("\r\n")
	}
	line("BEGIN:VCALENDAR")
	line("VERSION:2.0")
	line("PRODID:-//zortex//zortex serve//EN")
	line("CALSCALE:GREGORIAN")
	line("METHOD:PUBLISH")
	line("X-WR-CALNAME:" + escape(name))
	for _, e := range events {
		line("BEGIN:VEVENT")
		line("UID:" + e.UID)
		line("DTSTAMP:" + stamp.UTC().Format("20060102T150405Z"))
		if e.AllDay {
			line("DTSTART;VALUE=DATE:" + e.Start.Format("20060102"))
			line("DTEND;VALUE=DATE:" + e.End.Format("20060102"))
		} else {
			line("DTSTART:" + e.Start.UTC().Format("20060102T150405Z"))
			line("DTEND:" + e.End.UTC().Format("20060102T150405Z"))
		}
		line("SUMMARY:" + escape(e.Summary))
		if e.Description != "" {
			line("DESCRIPTION:" + escape(e.Description))
		}
		if e.URL != "" {
			line("URL:" + e.URL)
		}
		line("END:VEVENT")
	}
	line("END:VCALENDAR")
	_, err := fmt.Fprint(w, b.String())
	return err
}
