package web

import (
	"bufio"
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
	"net/http"
	"os"
	"strings"
)

// A login for people who don't put the server behind a proxy that has one
// (-auth-file / ZORTEX_AUTH): HTTP basic auth against "user:password"
// lines. Use it over HTTPS (a proxy, Tailscale): basic auth sends the
// password with every request.
//
// Not asked for: /healthz and /health (health checks), and requests with a
// valid X-API-Key (Neovim) when -api-key is set.

// Account is one login.
type Account struct {
	User     string
	Password string
}

// ParseAccounts reads "user:password" lines (blank lines and # comments
// skipped).
func ParseAccounts(text string) ([]Account, error) {
	var out []Account
	sc := bufio.NewScanner(strings.NewReader(text))
	n := 0
	for sc.Scan() {
		n++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		user, pass, ok := strings.Cut(line, ":")
		if !ok || user == "" || pass == "" {
			return nil, fmt.Errorf("line %d: want user:password", n)
		}
		out = append(out, Account{User: user, Password: pass})
	}
	return out, sc.Err()
}

// ReadAccounts reads an accounts file.
func ReadAccounts(path string) ([]Account, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	accounts, err := ParseAccounts(string(raw))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if len(accounts) == 0 {
		return nil, fmt.Errorf("%s: no user:password lines", path)
	}
	return accounts, nil
}

func digest(s string) []byte {
	h := sha256.Sum256([]byte(s))
	return h[:]
}

// loginOK: the request's basic auth matches an account (compared in
// constant time, every account checked).
func (s *Server) loginOK(r *http.Request) bool {
	user, pass, ok := r.BasicAuth()
	if !ok {
		return false
	}
	u, p := digest(user), digest(pass)
	match := 0
	for _, a := range s.cfg.Accounts {
		match |= subtle.ConstantTimeCompare(u, digest(a.User)) & subtle.ConstantTimeCompare(p, digest(a.Password))
	}
	return match == 1
}

func (s *Server) requireLogin(h http.Handler) http.Handler {
	if len(s.cfg.Accounts) == 0 {
		return h
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, s.cfg.Base)
		if path == "/healthz" || path == "/health" || s.pwaPublic(path) || s.sharePublic(path, r) {
			h.ServeHTTP(w, r)
			return
		}
		if s.cfg.APIKey != "" && r.Header.Get("X-API-Key") != "" && s.keyOK(r) {
			h.ServeHTTP(w, r)
			return
		}
		if !s.loginOK(r) {
			w.Header().Set("WWW-Authenticate", `Basic realm="`+strings.ReplaceAll(s.cfg.Title, `"`, "")+`", charset="UTF-8"`)
			http.Error(w, "login required", http.StatusUnauthorized)
			return
		}
		h.ServeHTTP(w, r)
	})
}
