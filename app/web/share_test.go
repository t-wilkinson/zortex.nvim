package web

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/feeds"
	"github.com/t-wilkinson/zortex.nvim/app/ical"
)

func fetchAs(t *testing.T, url string, user, pass string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest("GET", url, nil)
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// /calendar.ics: only the @share lines, behind the login or the token
func TestShareFeed(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	day := time.Now().Format("2006-01-02")
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte("@@Calendar\n\n**"+day+":**\n"+
		"09:00 - 10:30 Deep work on [P/#1.4 - zortex] @share\n"+
		"12:00 Lunch with Sam\n"+
		"- Mum's birthday @share\n"+
		"16:00 [ ] Pick up the kids @share @id(kid01)\n"), 0o644)
	s.Refresh()

	// no token configured: like any page (no login in this test)
	code, body := fetchAs(t, ts.URL+"/calendar.ics", "", "")
	if code != 200 {
		t.Fatalf("%d", code)
	}
	events := ical.Parse(strings.NewReader(body), time.Local)
	var got []string
	for _, e := range events {
		got = append(got, e.Start.In(time.Local).Format("15:04")+"-"+e.End.In(time.Local).Format("15:04")+" "+e.Summary)
	}
	want := []string{"09:00-10:30 Deep work on 1.4 - zortex", "00:00-00:00 Mum's birthday", "16:00-16:30 Pick up the kids"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got:\n%s\nwant:\n%s\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"), body)
	}
	if !events[1].AllDay || events[2].UID != "kid01-"+day+"@zortex" || strings.Contains(body, "Lunch") {
		t.Fatalf("%+v\n%s", events, body)
	}

	// a token, and no login of the app's own: only the token gets in
	s.cfg.ShareToken = "0123456789abcdef0123"
	if code, _ := fetchAs(t, ts.URL+"/calendar.ics", "", ""); code != 404 {
		t.Fatalf("without the token: %d", code)
	}
	if code, _ := fetchAs(t, ts.URL+"/calendar.ics?token=wrong", "", ""); code != 404 {
		t.Fatalf("wrong token: %d", code)
	}
	if code, body := fetchAs(t, ts.URL+"/calendar.ics?token=0123456789abcdef0123", "", ""); code != 200 || !strings.Contains(body, "Mum's birthday") {
		t.Fatalf("with the token: %d", code)
	}
}

func TestShareFeedWithLogin(t *testing.T) {
	s, _, _ := newTestServer(t, "")
	s.cfg.Accounts = []Account{{User: "me", Password: "secret"}}
	s.cfg.ShareToken = "0123456789abcdef0123"
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	ts := srv.URL
	if code, _ := fetchAs(t, ts+"/calendar.ics", "", ""); code != 401 {
		t.Fatalf("no login, no token: %d", code)
	}
	if code, _ := fetchAs(t, ts+"/calendar.ics?token=0123456789abcdef0123", "", ""); code != 200 {
		t.Fatalf("the token skips the login: %d", code)
	}
	if code, _ := fetchAs(t, ts+"/calendar.ics", "me", "secret"); code != 200 {
		t.Fatalf("the login works too: %d", code)
	}
	if code, _ := fetchAs(t, ts+"/?token=0123456789abcdef0123", "", ""); code != 401 {
		t.Fatalf("the token opens nothing else: %d", code)
	}
}

// a calendar feed's note shows among the day's entries on the web
func TestFeedInCalendar(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	day := time.Now().Format("2006-01-02")
	os.WriteFile(filepath.Join(dir, "calendar.zortex"), []byte("@@Calendar\n\n**"+day+":**\n09:00 Work\n17:00 Gym\n"), 0o644)
	os.MkdirAll(filepath.Join(dir, "z", "feeds"), 0o755)
	os.WriteFile(filepath.Join(dir, "z", "feeds", "cozi.zortex"), []byte(strings.Join([]string{
		"@@Cozi", feeds.Marker, "", "**" + day + ":**", "- Camping", "12:30 - 13:00 Dentist @n(no)",
	}, "\n")+"\n"), 0o644)
	s.Refresh()
	days := s.calendarDays(day, day)
	var got []string
	for _, e := range days[day] {
		got = append(got, e.Time+" "+e.Text+" "+e.Feed)
	}
	want := []string{" Camping cozi", "09:00 Work ", "12:30 Dentist cozi", "17:00 Gym "}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("%q", got)
	}
	for _, e := range days[day] {
		if e.Feed != "" && (e.Src != "" || e.Rel != "") {
			t.Fatal("feed entries are read-only")
		}
	}
	_ = ts
}
