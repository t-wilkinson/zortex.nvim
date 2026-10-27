//go:build !linux

package web

import "context"

// watchFolder: no file watching off Linux; the folder is rescanned every
// Config.Poll.
func watchFolder(ctx context.Context, root string, logf func(string, ...any)) <-chan struct{} {
	return nil
}
