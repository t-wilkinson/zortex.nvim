package alerts

import (
	"context"
	"log"
	"time"
)

// Sender delivers due notifications through ntfy. Run it in a goroutine.
// OnFire, when set, is called with every notification as it comes due
// (sent through ntfy or not; not one skipped for being too late), so the
// server can pass it on (GET /api/alerts, which Neovim shows).
type Sender struct {
	Store    *Store
	Ntfy     *Ntfy
	Interval time.Duration // how often to look for due notifications (default 20s)
	// MaxLate: a notification that comes due while the server is down is
	// still sent when it comes back, unless it is more than MaxLate overdue
	// (then it is marked skipped). 0: 2h.
	MaxLate   time.Duration
	KeepSent  time.Duration // default 7 days
	KeepStale time.Duration // pending but long overdue; default 30 days
	Logger    *log.Logger
	OnFire    func(Notification)

	kick chan struct{}
}

func (s *Sender) defaults() {
	if s.Interval <= 0 {
		s.Interval = 20 * time.Second
	}
	if s.MaxLate <= 0 {
		s.MaxLate = 2 * time.Hour
	}
	if s.KeepSent <= 0 {
		s.KeepSent = 7 * 24 * time.Hour
	}
	if s.KeepStale <= 0 {
		s.KeepStale = 30 * 24 * time.Hour
	}
	if s.Logger == nil {
		s.Logger = log.Default()
	}
	if s.kick == nil {
		s.kick = make(chan struct{}, 1)
	}
}

// Kick asks the sender to look for due notifications now.
func (s *Sender) Kick() {
	s.defaults()
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// Run sends due notifications until ctx is done.
func (s *Sender) Run(ctx context.Context) {
	s.defaults()
	t := time.NewTicker(s.Interval)
	defer t.Stop()
	lastCleanup := time.Time{}
	for {
		s.SendDue(ctx, time.Now())
		if time.Since(lastCleanup) > time.Hour {
			if n, err := s.Store.Cleanup(time.Now(), s.KeepSent, s.KeepStale); err != nil {
				s.Logger.Printf("notifications: cleanup: %v", err)
			} else if n > 0 {
				s.Logger.Printf("notifications: cleaned up %d old notifications", n)
			}
			lastCleanup = time.Now()
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-s.kick:
		}
	}
}

func (s *Sender) fire(n Notification) {
	if s.OnFire != nil {
		s.OnFire(n)
	}
}

// SendDue sends every notification due at now. Returns how many were sent.
func (s *Sender) SendDue(ctx context.Context, now time.Time) int {
	s.defaults()
	sent := 0
	for _, n := range s.Store.Due(now) {
		late := now.Sub(time.Unix(n.ScheduledTime, 0))
		if late > s.MaxLate {
			_ = s.Store.MarkSent(n.ID, now, true)
			s.Logger.Printf("notifications: skipped %d %q (%s late)", n.ID, n.Title, late.Round(time.Minute))
			continue
		}
		if !s.Ntfy.Enabled() {
			// Nothing to deliver through: keep the calendar view accurate
			_ = s.Store.MarkSent(n.ID, now, true)
			s.fire(n)
			continue
		}
		err := s.Ntfy.Publish(ctx, Message{Title: n.Title, Message: n.Message, Priority: n.Priority, Tags: n.Tags})
		if err != nil {
			s.Logger.Printf("notifications: send %d %q: %v", n.ID, n.Title, err)
			continue // retried on the next tick
		}
		_ = s.Store.MarkSent(n.ID, now, false)
		s.fire(n)
		sent++
	}
	return sent
}
