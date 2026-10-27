//go:build linux

package web

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func waitChange(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatalf("no change seen after %s", what)
	}
}

func noChange(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
		t.Fatalf("a change seen after %s", what)
	case <-time.After(400 * time.Millisecond):
	}
}

func TestWatchFolder(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, ".stversions"), 0o755)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := watchFolder(ctx, root, t.Logf)
	if ch == nil {
		t.Skip("inotify isn't available here")
	}

	os.WriteFile(filepath.Join(root, "a.zortex"), []byte("@@A\n"), 0o644)
	waitChange(t, ch, "writing a note")

	// a burst is one change
	for i := 0; i < 5; i++ {
		os.WriteFile(filepath.Join(root, "a.zortex"), []byte("@@A\nline\n"), 0o644)
	}
	waitChange(t, ch, "a burst")
	noChange(t, ch, "the burst settled")

	// Syncthing: a temp file renamed into place counts once, at the rename
	tmp := filepath.Join(root, ".syncthing.b.zortex.tmp")
	os.WriteFile(tmp, []byte("@@B\n"), 0o644)
	noChange(t, ch, "writing Syncthing's temp file")
	os.Rename(tmp, filepath.Join(root, "b.zortex"))
	waitChange(t, ch, "renaming it into place")

	// a new folder is watched too
	os.MkdirAll(filepath.Join(root, "z", "books"), 0o755)
	waitChange(t, ch, "making a folder")
	time.Sleep(50 * time.Millisecond)
	os.WriteFile(filepath.Join(root, "z", "books", "c.zortex"), []byte("@@C\n"), 0o644)
	waitChange(t, ch, "writing in a new folder")

	// hidden folders are not, but .z (the notes' state) is
	os.WriteFile(filepath.Join(root, ".stversions", "old.zortex"), []byte("x"), 0o644)
	noChange(t, ch, "writing in .stversions")
	os.MkdirAll(filepath.Join(root, ".z"), 0o755)
	waitChange(t, ch, "making .z")
	time.Sleep(50 * time.Millisecond)
	os.WriteFile(filepath.Join(root, ".z", "xp.json"), []byte("{}"), 0o644)
	waitChange(t, ch, "writing .z/xp.json")

	cancel()
	select {
	case _, ok := <-ch:
		if ok {
			if _, ok = <-ch; ok {
				t.Fatal("the channel stays open after the context ends")
			}
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the channel stays open after the context ends")
	}
}

// A note written to the folder shows on the site without waiting for the
// rescan timer.
func TestRunPicksUpChangesBeforeThePoll(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "a.zortex"), []byte("@@Alpha\n"), 0o644)
	s, err := New(Config{Root: root, Poll: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.Run(ctx)
	time.Sleep(100 * time.Millisecond)
	os.WriteFile(filepath.Join(root, "b.zortex"), []byte("@@Beta\n"), 0o644)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if s.current().notes == 2 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("notes = %d, want 2 before the hour's rescan", s.current().notes)
}
