package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"golang.org/x/time/rate"
)

// ===========================================================================
// memscan leaderboard backend. A single static binary: net/http + pure-Go SQLite. Put it behind
// nginx/Caddy for TLS. Config comes from env vars (see config.go / README.md). Endpoints:
//   POST /api/v1/submit            - verify + store a signed run
//   GET  /api/v1/leaderboard       - ranked rows (?sort=penya|kpm|kills|monsters|density&limit=N)
//   GET  /api/v1/entry/{id}/config - that entry's flyff.cfg blob (text/plain)
// ===========================================================================

func main() {
	cfg := loadConfig()
	db, err := openDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("open db %q: %v", cfg.DBPath, err)
	}
	defer db.Close()

	srv := &Server{cfg: cfg, db: db, rl: newRateLimiter(rate.Limit(cfg.RateRPS), cfg.RateBurst)}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/submit", srv.handleSubmit)
	mux.HandleFunc("/api/v1/leaderboard", srv.handleLeaderboard)
	mux.HandleFunc("/api/v1/entry/", srv.handleEntryConfig) // {id}/config
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })

	handler := srv.rl.middleware(logRequests(mux))

	httpSrv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown on SIGINT/SIGTERM.
	go func() {
		log.Printf("listening on %s (min_sec=%d, allowlist=%d hashes)", cfg.Listen, cfg.MinSec, len(cfg.AllowedHashes))
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("serve: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Print("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(ctx)
}

// logRequests is a tiny access log (method, path, status, duration) - handy for tuning rate limits and
// spotting rejection storms.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		log.Printf("%s %s -> %d (%s) ip=%s", r.Method, r.URL.Path, sw.status, time.Since(start), clientIP(r))
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// ===========================================================================
// Rate limiting: a per-IP token bucket plus a global ceiling, protecting the VPS from floods. The
// per-IP limiters live in a map pruned of idle entries so a flood of distinct IPs can't grow it forever.
// ===========================================================================

type ipLimiter struct {
	lim  *rate.Limiter
	seen time.Time
}

type rateLimiter struct {
	mu     sync.Mutex
	ips    map[string]*ipLimiter
	rps    rate.Limit
	burst  int
	global *rate.Limiter
}

func newRateLimiter(rps rate.Limit, burst int) *rateLimiter {
	rl := &rateLimiter{
		ips:    map[string]*ipLimiter{},
		rps:    rps,
		burst:  burst,
		global: rate.NewLimiter(rps*50+50, burst*20+100), // generous global cap above the sum of well-behaved IPs
	}
	go rl.reaper()
	return rl
}

func (rl *rateLimiter) get(ip string) *rate.Limiter {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	l, ok := rl.ips[ip]
	if !ok {
		l = &ipLimiter{lim: rate.NewLimiter(rl.rps, rl.burst)}
		rl.ips[ip] = l
	}
	l.seen = time.Now()
	return l.lim
}

// reaper drops per-IP limiters idle for >10 min so the map stays bounded.
func (rl *rateLimiter) reaper() {
	t := time.NewTicker(5 * time.Minute)
	for range t.C {
		cutoff := time.Now().Add(-10 * time.Minute)
		rl.mu.Lock()
		for ip, l := range rl.ips {
			if l.seen.Before(cutoff) {
				delete(rl.ips, ip)
			}
		}
		rl.mu.Unlock()
	}
}

func (rl *rateLimiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !rl.global.Allow() {
			writeErr(w, http.StatusTooManyRequests, "server busy")
			return
		}
		if !rl.get(clientIP(r)).Allow() {
			writeErr(w, http.StatusTooManyRequests, "rate limited")
			return
		}
		next.ServeHTTP(w, r)
	})
}
