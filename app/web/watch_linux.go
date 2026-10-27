//go:build linux

package web

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// watchFolder tells the server as soon as a file under root changes, so a
// note synced from a phone shows in about a second instead of on the next
// rescan (Config.Poll keeps running as a safety net). It uses inotify, one
// watch per folder; nil when inotify isn't available (the rescan still
// runs). Bursts of events (Syncthing writing several files) are sent as
// one, after a short quiet spell.
func watchFolder(ctx context.Context, root string, logf func(string, ...any)) <-chan struct{} {
	fd, err := syscall.InotifyInit1(syscall.IN_NONBLOCK | syscall.IN_CLOEXEC)
	if err != nil {
		logf("watch: %v (rescanning on a timer only)", err)
		return nil
	}
	// a non-blocking descriptor is read through Go's poller, so Close below
	// ends the blocked Read
	f := os.NewFile(uintptr(fd), "inotify")
	w := &watcher{fd: fd, dirs: map[int32]string{}, logf: logf}
	w.addTree(root, root)
	if len(w.dirs) == 0 {
		f.Close()
		return nil
	}
	go func() {
		<-ctx.Done()
		f.Close()
	}()

	raw := make(chan struct{}, 1)
	go func() {
		buf := make([]byte, 64*1024)
		for {
			n, err := f.Read(buf)
			if err != nil {
				if !errors.Is(err, os.ErrClosed) && ctx.Err() == nil {
					logf("watch: %v (rescanning on a timer only)", err)
				}
				close(raw)
				return
			}
			if w.handle(root, buf[:n]) {
				select {
				case raw <- struct{}{}:
				default:
				}
			}
		}
	}()

	out := make(chan struct{}, 1)
	go func() {
		defer close(out)
		const quiet, longest = 150 * time.Millisecond, time.Second
		for {
			if _, ok := <-raw; !ok {
				return
			}
			// wait for the burst to settle, but not forever
			first := time.Now()
			timer := time.NewTimer(quiet)
		settle:
			for {
				select {
				case _, ok := <-raw:
					if !ok {
						timer.Stop()
						return
					}
					if time.Since(first) < longest {
						timer.Reset(quiet)
					}
				case <-timer.C:
					break settle
				}
			}
			select {
			case out <- struct{}{}:
			default:
			}
		}
	}()
	return out
}

type watcher struct {
	fd   int
	dirs map[int32]string // watch descriptor -> folder
	logf func(string, ...any)
	full bool // the watch limit was reached (logged once)
}

const watchMask = syscall.IN_CLOSE_WRITE | syscall.IN_MOVED_TO | syscall.IN_MOVED_FROM |
	syscall.IN_CREATE | syscall.IN_DELETE | syscall.IN_DELETE_SELF | syscall.IN_ATTRIB |
	syscall.IN_ONLYDIR | syscall.IN_EXCL_UNLINK

// skipDir: folders not worth watching: hidden ones (.git, .stversions,
// .stfolder, .trash) but the notes' own .z state.
func skipDir(root, path, name string) bool {
	return path != root && strings.HasPrefix(name, ".") && !(name == ".z" && filepath.Dir(path) == root)
}

func (w *watcher) addTree(root, dir string) {
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil
		}
		if skipDir(root, path, d.Name()) {
			return filepath.SkipDir
		}
		wd, err := syscall.InotifyAddWatch(w.fd, path, watchMask)
		if err != nil {
			if errors.Is(err, syscall.ENOSPC) && !w.full {
				w.full = true
				w.logf("watch: too many folders for inotify (raise fs.inotify.max_user_watches); the rest are rescanned on a timer")
			}
			return nil
		}
		w.dirs[int32(wd)] = path
		return nil
	})
}

// handle reads a buffer of inotify events: true when one is about a file
// the server reads. New folders are watched as they appear.
func (w *watcher) handle(root string, buf []byte) bool {
	changed := false
	for off := 0; off+syscall.SizeofInotifyEvent <= len(buf); {
		ev := (*syscall.InotifyEvent)(unsafe.Pointer(&buf[off]))
		nameBytes := buf[off+syscall.SizeofInotifyEvent : off+syscall.SizeofInotifyEvent+int(ev.Len)]
		off += syscall.SizeofInotifyEvent + int(ev.Len)
		name := strings.TrimRight(string(nameBytes), "\x00")
		dir, ok := w.dirs[ev.Wd]
		switch {
		case ev.Mask&syscall.IN_Q_OVERFLOW != 0:
			changed = true
			continue
		case ev.Mask&syscall.IN_IGNORED != 0:
			delete(w.dirs, ev.Wd)
			continue
		case !ok:
			continue
		}
		path := filepath.Join(dir, name)
		if ev.Mask&syscall.IN_ISDIR != 0 {
			if ev.Mask&(syscall.IN_CREATE|syscall.IN_MOVED_TO) != 0 && !skipDir(root, path, name) {
				w.addTree(root, path)
			}
			changed = true
			continue
		}
		if ignoredName(name) {
			continue
		}
		changed = true
	}
	return changed
}

// ignoredName: files being written that are renamed into place when done
// (that rename is the event that counts): Syncthing's .syncthing.*.tmp,
// editors' swap and backup files.
func ignoredName(name string) bool {
	return strings.HasPrefix(name, ".syncthing.") || strings.HasSuffix(name, ".swp") ||
		strings.HasSuffix(name, ".swx") || strings.HasSuffix(name, "~") || name == "4913"
}
