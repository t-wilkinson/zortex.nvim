package web

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const groupNote = "@@Homelab\n@P\n\n# Security\n" +
	"- [ ] Security audit @id(grp01) @md\n" +
	"    - [./z/generated/audit.md]\n" +
	"    - [ ] Cloudflare tunnel\n" +
	"    - [x] Cloudflare cert @done(2026-10-11)\n" +
	"    - [ ] Wi-Fi password\n" +
	"    - [ ] SSH host key\n"

// Tasks nested under a task (edit.Groups): the project page lists them, each
// with its share of the group's size, and counts them, not the group.
func TestTaskGroupsOnProjectPages(t *testing.T) {
	s, dir, ts := writableServer(t)
	if err := os.WriteFile(filepath.Join(dir, "homelab.zortex"), []byte(groupNote), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	p := projectByName(s.allProjects(), "Security")
	if p == nil {
		t.Fatal("no project")
	}
	if len(p.Tasks) != 4 {
		t.Fatalf("tasks: %d", len(p.Tasks))
	}
	for _, task := range p.Tasks {
		if math.Abs(task.Hours-0.25) > 1e-9 || task.Group != "Security audit" {
			t.Errorf("task %q: %v h, group %q", task.Line, task.Hours, task.Group)
		}
	}
	r := p.rollup()
	if r.Total != 4 || r.DoneN != 1 || math.Abs(r.Hours-1) > 1e-9 {
		t.Fatalf("rollup %+v", r)
	}
	page := expect(t, ts, "/project?rel=homelab.zortex&lnum=4", 200)
	if !strings.Contains(page, `title="a task of this group">Security audit › </span>`) {
		t.Error("project page: the group isn't named next to its tasks")
	}
}

// Checking a group on the web checks its tasks; the last task checks the group.
func TestTaskGroupsCascadeOnTheWeb(t *testing.T) {
	s, dir, ts := writableServer(t)
	path := filepath.Join(dir, "homelab.zortex")
	if err := os.WriteFile(path, []byte(groupNote), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	today := time.Now().Format("2006-01-02")
	lines := readLines(t, path)
	n := lineOf(t, lines, "Security audit")
	code, out := postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "homelab.zortex", "lnum": n, "expect": lines[n-1], "op": "toggle"})
	if code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	got := readLines(t, path)
	for _, want := range []string{"Cloudflare tunnel @id(", "Wi-Fi password", "SSH host key"} {
		l := got[lineOf(t, got, strings.SplitN(want, " @", 2)[0])-1]
		if !strings.Contains(l, "- [x] ") || !strings.Contains(l, "@done("+today+")") {
			t.Errorf("not checked with the group: %q", l)
		}
	}
	if l := got[lineOf(t, got, "Cloudflare cert")-1]; !strings.Contains(l, "@done(2026-10-11)") {
		t.Errorf("an already checked task kept its date: %q", l)
	}
	// reopen one: the group reopens
	m := lineOf(t, got, "Wi-Fi password")
	postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "homelab.zortex", "lnum": m, "expect": got[m-1], "op": "toggle"})
	got = readLines(t, path)
	if l := got[n-1]; !strings.HasPrefix(l, "- [ ] Security audit") {
		t.Fatalf("group still checked: %q", l)
	}
	// check it again, the last open one: the group follows
	postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "homelab.zortex", "lnum": m, "expect": got[m-1], "op": "toggle"})
	got = readLines(t, path)
	if l := got[n-1]; !strings.HasPrefix(l, "- [x] Security audit") {
		t.Fatalf("group not checked by its last task: %q", l)
	}
}

// A group's copy on the calendar, checked on the web, checks the group's
// tasks in the project note.
func TestTaskGroupCopyOnTheCalendar(t *testing.T) {
	s, dir, ts := writableServer(t)
	path := filepath.Join(dir, "homelab.zortex")
	if err := os.WriteFile(path, []byte(groupNote), 0o644); err != nil {
		t.Fatal(err)
	}
	day := time.Now().Format("2006-01-02")
	cal := "@@Calendar\n\n" + day + ":\n- [ ] [P/Homelab/#Security/-Security audit] @id(grp01)\n"
	calPath := filepath.Join(dir, "calendar.zortex")
	if err := os.WriteFile(calPath, []byte(cal), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	cl := readLines(t, calPath)
	code, out := postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "calendar.zortex", "lnum": 4, "expect": cl[3], "op": "toggle"})
	if code != 200 {
		t.Fatalf("toggle copy: %d %v", code, out)
	}
	got := readLines(t, path)
	for _, want := range []string{"Security audit", "Cloudflare tunnel", "Wi-Fi password", "SSH host key"} {
		if l := got[lineOf(t, got, want)-1]; !strings.Contains(l, "[x]") {
			t.Errorf("not checked: %q", l)
		}
	}
}

// A task of a group ticked on the web is estimated at its share.
func TestTaskGroupShareInPendingXP(t *testing.T) {
	s, dir, ts := writableServer(t)
	path := filepath.Join(dir, "homelab.zortex")
	if err := os.WriteFile(path, []byte(groupNote), 0o644); err != nil {
		t.Fatal(err)
	}
	s.Refresh()
	lines := readLines(t, path)
	m := lineOf(t, lines, "Wi-Fi password")
	if code, out := postJSON(t, ts.URL, "/api/edit", map[string]any{"rel": "homelab.zortex", "lnum": m, "expect": lines[m-1], "op": "toggle"}); code != 200 {
		t.Fatalf("toggle: %d %v", code, out)
	}
	body := expect(t, ts, "/api/xp", 200)
	if !strings.Contains(body, `"title":"Wi-Fi password"`) || !strings.Contains(body, `"hours":0.25`) {
		t.Fatalf("pending: %s", body)
	}
}
