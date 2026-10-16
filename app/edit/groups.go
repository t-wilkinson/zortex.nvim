package edit

// Task groups: tasks nested under a task (lua/zortex/services/task_groups.lua
// has the rules; tests/fixtures/groups.json checks both sides agree).
//
//	hours    a task without children: its @size in hours (unsized: md),
//	         unless a group above gives it a share. A group with an @size:
//	         that size, split over its children in proportion to their own
//	         hours (sized: its size, unsized: md, a sub-group: its total).
//	         A group without one: the sum of its children. Progress and XP
//	         count the leaves.
//	done     a leaf is done when checked, or when a group above it is
//	         (dated by the nearest checked group's @done when it has none).
//	cascade  checking a group checks its open tasks; checking the last open
//	         child checks the group; reopening a child reopens the groups
//	         above it.

import (
	"sort"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

func groupIndent(line string) int {
	w := 0
	for _, c := range line {
		switch c {
		case ' ':
			w++
		case '\t':
			w += 4
		default:
			return w
		}
	}
	return w
}

// GroupParents: for every task line (1-based) of lines, the line of the task
// it is nested under, or 0. Carried tasks ([>]) are not tasks here.
func GroupParents(lines []string) map[int]int {
	ast := syntax.Parse(lines, false)
	type entry struct {
		indent, lnum int
		task         bool
	}
	var stack []entry
	out := map[int]int{}
	for i, d := range ast.Lines {
		l := i + 1
		switch d.Kind {
		case syntax.KindBlank, syntax.KindCode, syntax.KindFence, syntax.KindMath, syntax.KindMathFence:
			continue
		case syntax.KindHeading, syntax.KindBoldHeading, syntax.KindArticle, syntax.KindTag:
			stack = stack[:0]
			continue
		}
		w := groupIndent(lines[i])
		for len(stack) > 0 && stack[len(stack)-1].indent >= w {
			stack = stack[:len(stack)-1]
		}
		isTask := d.Item != nil && d.Item.Mark != "" && d.Item.Mark != Moved
		if isTask {
			parent := 0
			for j := len(stack) - 1; j >= 0; j-- {
				if stack[j].task {
					parent = stack[j].lnum
					break
				}
			}
			out[l] = parent
		}
		stack = append(stack, entry{w, l, isTask})
	}
	return out
}

// GroupTask: a task's place in its group.
type GroupTask struct {
	Lnum          int
	Parent        int   // the group it is in (0: none)
	Children      []int // its tasks
	Leaf          bool
	Hours         float64 // its hours, or its share of the group's
	DoneEffective bool    // a leaf: checked, or under a checked group
	DoneDate      string  // its @done, or the checked group's above it
	OpenHours     float64 // open work: a leaf's hours, a group's open leaves'
	OpenLeaves    int
	P, I          string // priority and importance, from the groups above when it has none
}

// Groups annotates the tasks of lines[first..last] (1-based; 0, 0: all).
// hours gives a size's hours (ok false: unknown); def is md's.
func Groups(lines []string, first, last int, hours func(size string) (float64, bool), def float64) map[int]*GroupTask {
	if first < 1 {
		first = 1
	}
	if last < 1 || last > len(lines) {
		last = len(lines)
	}
	parents := GroupParents(lines)
	tasks := map[int]*GroupTask{}
	var order []int
	for l, p := range parents {
		if l >= first && l <= last {
			tasks[l] = &GroupTask{Lnum: l, Parent: p}
			order = append(order, l)
		}
	}
	sort.Ints(order)
	var roots []int
	for _, l := range order {
		t := tasks[l]
		if p, ok := tasks[t.Parent]; ok && t.Parent != 0 {
			p.Children = append(p.Children, l)
		} else {
			t.Parent = 0
			roots = append(roots, l)
		}
	}
	own := func(l int) (float64, bool) {
		size := sizeOf(lines[l-1])
		if size == "" {
			return 0, false
		}
		return hours(size)
	}
	natural := map[int]float64{}
	var nat func(l int) float64
	nat = func(l int) float64 {
		if v, ok := natural[l]; ok {
			return v
		}
		t := tasks[l]
		var h float64
		if o, ok := own(l); ok {
			h = o
		} else if len(t.Children) == 0 {
			h = def
		} else {
			for _, c := range t.Children {
				h += nat(c)
			}
		}
		natural[l] = h
		return h
	}
	type above struct {
		done bool
		date string
	}
	var assign func(l int, budget float64, up *above, p, i string)
	assign = func(l int, budget float64, up *above, p, i string) {
		t := tasks[l]
		line := lines[l-1]
		if v := attrOrBareFlag(line, "p"); v != "" {
			p = v
		}
		if v := attrOrBareFlag(line, "i"); v != "" {
			i = v
		}
		t.P, t.I = p, i
		t.Leaf = len(t.Children) == 0
		t.Hours = budget
		date, _ := Attribute(line, "done")
		checked := isChecked(line)
		if t.Leaf {
			t.DoneEffective = checked || up != nil
			t.DoneDate = date
			if t.DoneDate == "" && up != nil {
				t.DoneDate = up.date
			}
			if !t.DoneEffective {
				t.OpenHours, t.OpenLeaves = budget, 1
			}
			return
		}
		t.DoneDate = date
		// what its tasks inherit: the nearest checked group's date
		next := up
		if checked {
			d := date
			if d == "" && up != nil {
				d = up.date
			}
			next = &above{true, d}
		}
		var total float64
		for _, c := range t.Children {
			total += nat(c)
		}
		for _, c := range t.Children {
			share := budget / float64(len(t.Children))
			if total > 0 {
				share = budget * nat(c) / total
			}
			assign(c, share, next, p, i)
			t.OpenHours += tasks[c].OpenHours
			t.OpenLeaves += tasks[c].OpenLeaves
		}
	}
	for _, l := range roots {
		assign(l, nat(l), nil, "", "")
	}
	return tasks
}

// Ticked: the line is a ticked task ([x] or [X]).
func Ticked(line string) bool { return isChecked(line) }

func isChecked(line string) bool {
	_, mark, ok := task(line)
	return ok && completed(mark)
}

// sizeOf: @size(x), or a bare size word (@md).
func sizeOf(line string) string {
	if v, ok := Attribute(line, "size"); ok {
		return v
	}
	for _, f := range strings.Fields(line) {
		switch strings.TrimPrefix(f, "@") {
		case "xs", "sm", "md", "lg", "xl", "2xl", "3xl", "4xl", "5xl":
			if strings.HasPrefix(f, "@") {
				return f[1:]
			}
		}
	}
	return ""
}

// attrOrBareFlag: @p(1) or @p1 -> "1".
func attrOrBareFlag(line, key string) string {
	if v, ok := Attribute(line, key); ok {
		return v
	}
	for _, f := range strings.Fields(line) {
		if len(f) == 3 && f[0] == '@' && f[1] == key[0] && f[2] >= '1' && f[2] <= '3' {
			return f[2:]
		}
	}
	return ""
}

// Cascade: the edits that follow line lnum (1-based) having been checked or
// reopened (its new state is on the line), in line order.
func Cascade(lines []string, lnum int, today string) []LineEdit {
	parents := GroupParents(lines)
	if _, ok := parents[lnum]; !ok {
		return nil
	}
	children := map[int][]int{}
	for l, p := range parents {
		if p != 0 {
			children[p] = append(children[p], l)
		}
	}
	for _, c := range children {
		sort.Ints(c)
	}
	current := map[int]string{}
	line := func(l int) string {
		if v, ok := current[l]; ok {
			return v
		}
		return lines[l-1]
	}
	done := func(l int) bool { return isChecked(line(l)) }
	var edits []LineEdit
	set := func(l int, state bool) {
		current[l] = setDone(line(l), state, today)
		edits = append(edits, LineEdit{Lnum: l, Line: current[l]})
	}
	if done(lnum) {
		var down func(l int)
		down = func(l int) {
			for _, c := range children[l] {
				if !done(c) {
					set(c, true)
				}
				down(c)
			}
		}
		down(lnum)
		for p := parents[lnum]; p != 0; p = parents[p] {
			all := true
			for _, c := range children[p] {
				all = all && done(c)
			}
			if !all || done(p) {
				break
			}
			set(p, true)
		}
	} else {
		for p := parents[lnum]; p != 0; p = parents[p] {
			if done(p) {
				set(p, false)
			}
		}
	}
	sort.Slice(edits, func(a, b int) bool { return edits[a].Lnum < edits[b].Lnum })
	return edits
}
