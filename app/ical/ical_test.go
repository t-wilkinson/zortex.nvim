package ical

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func ny(t *testing.T) *time.Location {
	t.Helper()
	l, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skip("no zone database")
	}
	return l
}

const sample = "BEGIN:VCALENDAR\r\n" +
	"VERSION:2.0\r\n" +
	"PRODID:-//Cozi Inc//EN\r\n" +
	// a timed event in UTC
	"BEGIN:VEVENT\r\nUID:a1\r\nDTSTART:20261021T200000Z\r\nDTEND:20261021T210000Z\r\nSUMMARY:Soccer practice\r\nLOCATION:Field 3\\, north\r\n" +
	"BEGIN:VALARM\r\nTRIGGER:-PT15M\r\nSUMMARY:not the event\r\nEND:VALARM\r\nEND:VEVENT\r\n" +
	// all day, two days
	"BEGIN:VEVENT\r\nUID:a2\r\nDTSTART;VALUE=DATE:20261024\r\nDTEND;VALUE=DATE:20261026\r\nSUMMARY:Camping\r\nEND:VEVENT\r\n" +
	// weekly on Tue and Thu, in a TZID, 5 times, one moved and one skipped
	"BEGIN:VEVENT\r\nUID:a3\r\nDTSTART;TZID=America/New_York:20261020T073000\r\nDURATION:PT45M\r\n" +
	"RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=5\r\nEXDATE;TZID=America/New_York:20261022T073000\r\nSUMMARY:Swim\r\n" +
	"  lessons\r\nEND:VEVENT\r\n" + // folded: the first space goes
	"BEGIN:VEVENT\r\nUID:a3\r\nRECURRENCE-ID;TZID=America/New_York:20261027T073000\r\n" +
	"DTSTART;TZID=America/New_York:20261027T090000\r\nDTEND;TZID=America/New_York:20261027T094500\r\nSUMMARY:Swim lessons (late)\r\nEND:VEVENT\r\n" +
	// cancelled
	"BEGIN:VEVENT\r\nUID:a4\r\nDTSTART:20261023T150000Z\r\nSUMMARY:Called off\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n" +
	// monthly on the last Friday, until the end of the year
	"BEGIN:VEVENT\r\nUID:a5\r\nDTSTART:20261030T230000Z\r\nDTEND:20261031T000000Z\r\nRRULE:FREQ=MONTHLY;BYDAY=-1FR;UNTIL=20261231T000000Z\r\nSUMMARY:Pizza night\r\nEND:VEVENT\r\n" +
	// yearly birthday
	"BEGIN:VEVENT\r\nUID:a6\r\nDTSTART;VALUE=DATE:20101102\r\nRRULE:FREQ=YEARLY\r\nSUMMARY:Bob's birthday\r\nEND:VEVENT\r\n" +
	"END:VCALENDAR\r\n"

func TestParseAndExpand(t *testing.T) {
	loc := ny(t)
	events := Parse(strings.NewReader(sample), loc)
	if len(events) != 7 {
		t.Fatalf("events: %d", len(events))
	}
	if events[0].Location != "Field 3, north" || events[0].Summary != "Soccer practice" {
		t.Fatalf("text: %+v", events[0])
	}
	if events[2].Summary != "Swim lessons" {
		t.Fatalf("unfolded: %q", events[2].Summary)
	}
	from := time.Date(2026, 10, 18, 0, 0, 0, 0, loc)
	to := time.Date(2026, 12, 31, 0, 0, 0, 0, loc)
	var got []string
	for _, o := range Expand(events, from, to) {
		got = append(got, o.Start.Format("01-02 15:04")+" "+o.End.Format("15:04")+" "+o.Summary)
	}
	want := []string{
		"10-20 07:30 08:15 Swim lessons",
		"10-21 16:00 17:00 Soccer practice", // 20:00Z is 16:00 in New York (EDT)
		"10-24 00:00 00:00 Camping",
		"10-27 09:00 09:45 Swim lessons (late)", // the override
		"10-29 07:30 08:15 Swim lessons",
		"10-30 19:00 20:00 Pizza night",
		"11-02 00:00 00:00 Bob's birthday",
		"11-03 07:30 08:15 Swim lessons", // after the clocks change: still 07:30
		"11-27 18:00 19:00 Pizza night",  // EST now
		"12-25 18:00 19:00 Pizza night",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestRules(t *testing.T) {
	loc := time.UTC
	start := time.Date(2026, 1, 31, 10, 0, 0, 0, loc)
	cases := []struct {
		rule string
		want []string
	}{
		// a monthly event on the 31st skips months without one
		{"FREQ=MONTHLY;COUNT=4", []string{"01-31", "03-31", "05-31", "07-31"}},
		{"FREQ=DAILY;INTERVAL=10;COUNT=3", []string{"01-31", "02-10", "02-20"}},
		{"FREQ=MONTHLY;BYMONTHDAY=1,-1;COUNT=4", []string{"01-31", "02-01", "02-28", "03-01"}},
		// 2026-01-31 is a Saturday: DTSTART is the first one
		{"FREQ=WEEKLY;INTERVAL=2;BYDAY=SA;COUNT=3", []string{"01-31", "02-14", "02-28"}},
		{"FREQ=YEARLY;BYMONTH=3;BYDAY=2SU;COUNT=2", []string{"03-08", "03-14"}},
	}
	for _, c := range cases {
		r, ok := parseRule(c.rule, loc)
		if !ok {
			t.Fatalf("%s: not read", c.rule)
		}
		e := Event{Start: start, End: start.Add(time.Hour), Rule: r}
		var got []string
		for _, ts := range starts(e, time.Date(2030, 1, 1, 0, 0, 0, 0, loc)) {
			got = append(got, ts.Format("01-02"))
		}
		if strings.Join(got, " ") != strings.Join(c.want, " ") {
			t.Errorf("%s: %v, want %v", c.rule, got, c.want)
		}
	}
}

func TestDuration(t *testing.T) {
	for in, want := range map[string]time.Duration{
		"PT45M": 45 * time.Minute, "P1D": 24 * time.Hour, "P1DT2H": 26 * time.Hour,
		"-PT15M": -15 * time.Minute, "P2W": 14 * 24 * time.Hour,
	} {
		if got, ok := parseDuration(in); !ok || got != want {
			t.Errorf("%s: %v", in, got)
		}
	}
}

func TestWriteReadsBack(t *testing.T) {
	loc := ny(t)
	var b bytes.Buffer
	start := time.Date(2026, 10, 21, 16, 0, 0, 0, loc)
	err := Write(&b, "Zortex", []Out{
		{UID: "x1@zortex", Summary: "Dentist, then; lunch", Start: start, End: start.Add(time.Hour), URL: "https://notes.example.com/n/calendar.zortex#L4"},
		{UID: "x2@zortex", Summary: strings.Repeat("long ", 30), Start: time.Date(2026, 10, 22, 0, 0, 0, 0, loc), End: time.Date(2026, 10, 23, 0, 0, 0, 0, loc), AllDay: true},
	}, start)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range strings.Split(b.String(), "\r\n") {
		if len(l) > 75 {
			t.Fatalf("not folded: %q", l)
		}
	}
	events := Parse(&b, loc)
	if len(events) != 2 || events[0].Summary != "Dentist, then; lunch" || !events[0].Start.Equal(start) || !events[1].AllDay {
		t.Fatalf("%+v", events)
	}
	if strings.TrimSpace(events[1].Summary) != strings.TrimSpace(strings.Repeat("long ", 30)) {
		t.Fatalf("folded summary: %q", events[1].Summary)
	}
}
