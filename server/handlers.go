package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Payload is the submission body. The JSON keys MUST match the client's Lb_Payload marshaling
// (src/flyff/leaderboard.odin) - Odin emits the struct field names verbatim (snake_case here).
type Payload struct {
	Name        string         `json:"name"`
	BuildHash   string         `json:"build_hash"`
	Version     string         `json:"version"`
	DurationSec int            `json:"duration_sec"`
	Kills       int            `json:"kills"`
	Penya       int64          `json:"penya"`
	MaxDensity  int            `json:"max_density"`
	Monsters    map[string]int `json:"monsters"`
	Config      string         `json:"config"`
	Nonce       string         `json:"nonce"`
	Ts          int64          `json:"ts"`
	Sig         string         `json:"sig"`
}

// Server bundles the config, DB, and rate limiter for the HTTP handlers.
type Server struct {
	cfg Config
	db  *DB
	rl  *rateLimiter
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, reason string) {
	writeJSON(w, code, map[string]string{"error": reason})
}

// handleSubmit is the verification pipeline. Every stage fails closed with a specific reason so the
// client can surface it and the operator can tune. Order matters (cheap checks first).
func (s *Server) handleSubmit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		writeErr(w, http.StatusUnsupportedMediaType, "expected application/json")
		return
	}
	// Body size cap (defense against giant config blobs); MaxBytesReader also guards the decode.
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBodyBytes)
	var p Payload
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json: "+err.Error())
		return
	}

	// 1) build-hash allowlist
	if !s.cfg.buildHashAllowed(p.BuildHash) {
		writeErr(w, http.StatusForbidden, "build not allowed")
		return
	}
	// 2) HMAC signature (constant-time). Blocks any submission not signed with the shared secret.
	if !verifySignature(s.cfg.Secret, &p) {
		writeErr(w, http.StatusForbidden, "bad signature")
		return
	}
	// 3) anti-replay: timestamp within the skew window (the nonce-unseen half is enforced at insert).
	now := time.Now().Unix()
	if p.Ts < now-s.cfg.SkewSec || p.Ts > now+s.cfg.SkewSec {
		writeErr(w, http.StatusForbidden, "timestamp out of range")
		return
	}
	// 4) plausibility
	if reason, ok := s.plausible(&p); !ok {
		writeErr(w, http.StatusUnprocessableEntity, reason)
		return
	}

	// 5) insert (kpm is recomputed server-side; the client's kpm is never trusted or stored from the wire)
	kpm := float64(p.Kills) * 60.0 / float64(p.DurationSec)
	monBytes, _ := json.Marshal(p.Monsters)
	id, err := s.db.insertEntry(&p, kpm, len(p.Monsters), string(monBytes), s.ipHash(r))
	if err == errDuplicateNonce {
		writeErr(w, http.StatusConflict, "duplicate submission (nonce seen)")
		return
	}
	if err != nil {
		log.Printf("insert error: %v", err)
		writeErr(w, http.StatusInternalServerError, "storage error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"id": id})
}

// plausible runs the sanity checks that keep obviously-fake or out-of-band numbers off the board. It is
// deliberately generous: false rejects are worse than the rare fake the layered gates already deter.
func (s *Server) plausible(p *Payload) (string, bool) {
	if p.DurationSec < s.cfg.MinSec {
		return fmt.Sprintf("run too short (need >= %d s)", s.cfg.MinSec), false
	}
	if p.DurationSec > 48*3600 {
		return "run improbably long", false
	}
	if p.Kills < 0 || p.Penya < 0 || p.MaxDensity < 0 {
		return "negative metric", false
	}
	kpm := float64(p.Kills) * 60.0 / float64(p.DurationSec)
	if kpm > s.cfg.MaxKPM {
		return "kill rate too high", false
	}
	if p.MaxDensity > s.cfg.MaxDensity {
		return "density too high", false
	}
	if p.Kills > 0 && p.Penya > int64(p.Kills+1)*s.cfg.MaxPenyaPerKill {
		return "penya-per-kill too high", false
	}
	// monster tally: counts must be sane and never exceed the kills (you can't attribute more mobs than
	// you killed). A little slack under kills is fine (a run that started mid-fight logs "?").
	sum := 0
	for name, c := range p.Monsters {
		if c < 0 {
			return "negative monster count", false
		}
		if len(name) == 0 || len(name) > 64 {
			return "bad monster name", false
		}
		sum += c
	}
	if sum > p.Kills+1 {
		return "monster tally exceeds kills", false
	}
	if p.Kills >= 10 && sum*2 < p.Kills {
		return "monster tally too low for kills", false
	}
	if !validName(p.Name) {
		return "invalid name", false
	}
	if !validNonce(p.Nonce) {
		return "invalid nonce", false
	}
	if !validConfigText(p.Config) {
		return "invalid config", false
	}
	return "", true
}

// validConfigText accepts only a small, printable-ASCII text blob (the shared farming config the client
// filters down to behavior keys). It rejects empty/oversized blobs, binary, and control characters, so a
// modified client can't stash non-text payloads in the config field. The blob is normally ~30 short lines.
func validConfigText(s string) bool {
	if len(s) == 0 || len(s) > 64*1024 {
		return false
	}
	lines := 1
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\n':
			lines++
		case c == '\r' || c == '\t':
			// allowed whitespace
		case c < 0x20 || c > 0x7e:
			return false // non-printable / non-ASCII
		}
	}
	return lines <= 500
}

// validName accepts 1..24 visible characters (letters, digits, spaces, and a small punctuation set).
func validName(n string) bool {
	n = strings.TrimSpace(n)
	if len(n) < 1 || len(n) > 24 {
		return false
	}
	for _, r := range n {
		if r > unicode.MaxASCII {
			return false // keep it simple + spoof-resistant: ASCII only
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == ' ' || strings.ContainsRune("_-.[]", r) {
			continue
		}
		return false
	}
	return true
}

// validNonce accepts exactly 32 lowercase hex chars (the client sends hex of 16 random bytes).
func validNonce(n string) bool {
	if len(n) != 32 {
		return false
	}
	_, err := hex.DecodeString(n)
	return err == nil
}

// handleLeaderboard serves the ranked rows. kpm is read from the stored (server-computed) column.
func (s *Server) handleLeaderboard(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	sort := r.URL.Query().Get("sort")
	limit := 100
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	rows, err := s.db.topEntries(sort, limit)
	if err != nil {
		log.Printf("query error: %v", err)
		writeErr(w, http.StatusInternalServerError, "query error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": rows})
}

// handleEntryConfig serves an entry's flyff.cfg blob as text/plain (the client writes it to a file).
func (s *Server) handleEntryConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	// path: /api/v1/entry/{id}/config
	rest := strings.TrimPrefix(r.URL.Path, "/api/v1/entry/")
	idStr := strings.TrimSuffix(rest, "/config")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, "bad entry id")
		return
	}
	cfg, ok, err := s.db.entryConfig(id)
	if err != nil {
		log.Printf("config query error: %v", err)
		writeErr(w, http.StatusInternalServerError, "query error")
		return
	}
	if !ok {
		writeErr(w, http.StatusNotFound, "no such entry")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"flyff_%d.cfg\"", id))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(cfg))
}

// ipHash returns a stable, non-reversible tag for the client IP (salted with the secret) so we can
// rate-limit / audit without storing raw addresses.
func (s *Server) ipHash(r *http.Request) string {
	ip := clientIP(r)
	sum := sha256.Sum256([]byte(s.cfg.Secret + "|" + ip))
	return hex.EncodeToString(sum[:8])
}

// clientIP prefers the leftmost X-Forwarded-For entry (set by a trusted reverse proxy) and falls back to
// the socket peer. Deploy behind nginx/Caddy so XFF is trustworthy.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		return strings.TrimSpace(parts[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
