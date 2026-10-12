package alerts

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Ntfy publishes messages to an ntfy server (https://ntfy.sh or self-hosted).
// Messages are published as JSON to the server root, so titles and messages
// may hold any UTF-8 (headers would not).
type Ntfy struct {
	URL   string // server, e.g. https://ntfy.sh
	Topic string
	Token string // bearer token (optional)
	// User and Password for basic auth (optional, used without Token)
	User, Password string
	Client         *http.Client
}

// Enabled reports whether the client has a server and a topic.
func (n *Ntfy) Enabled() bool { return n != nil && n.URL != "" && n.Topic != "" }

// Message is one ntfy message.
type Message struct {
	Title    string
	Message  string
	Priority string   // min, low, default, high, max/urgent, 1-5, or p1-p3 (zortex priorities)
	Tags     []string // emoji shortcodes render as emoji; others are shown as tags
	Click    string   // URL opened when the notification is tapped
}

// priorityNumber maps priority names to ntfy's 1-5. Zortex's @p(1..3) become
// high, default and low.
func priorityNumber(p string) int {
	switch strings.ToLower(strings.TrimSpace(p)) {
	case "1", "min":
		return 1
	case "2", "low", "p3":
		return 2
	case "4", "high", "p1":
		return 4
	case "5", "max", "urgent":
		return 5
	}
	return 3
}

// Publish sends m.
func (n *Ntfy) Publish(ctx context.Context, m Message) error {
	if !n.Enabled() {
		return fmt.Errorf("ntfy is not configured")
	}
	body := map[string]any{
		"topic":    n.Topic,
		"title":    m.Title,
		"message":  m.Message,
		"priority": priorityNumber(m.Priority),
	}
	if body["message"] == "" {
		body["message"] = m.Title // ntfy requires a message
	}
	if len(m.Tags) > 0 {
		body["tags"] = m.Tags
	}
	if m.Click != "" {
		body["click"] = m.Click
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(n.URL, "/"), bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if n.Token != "" {
		req.Header.Set("Authorization", "Bearer "+n.Token)
	} else if n.User != "" {
		req.SetBasicAuth(n.User, n.Password)
	}
	client := n.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("ntfy: %s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	return nil
}
