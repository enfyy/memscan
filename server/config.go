package main

import (
	"log"
	"os"
	"strconv"
	"strings"
)

// Config is the whole server configuration, read once from environment variables at startup.
// Everything is overridable so the same binary serves local testing (LB_MIN_SEC=60, empty allowlist)
// and production (LB_MIN_SEC=600, a real allowlist) without a rebuild.
type Config struct {
	Secret       string          // HMAC secret; MUST equal the client's LEADERBOARD_SECRET. Fatal if empty.
	AllowedHashes map[string]bool // official BUILD_HASH allowlist; empty => dev mode (accept any, with a warning)
	DBPath       string
	Listen       string
	MinSec       int   // minimum accepted duration_sec (the "10 minute" rule; lower only for local testing)
	MaxKPM       float64
	MaxDensity   int
	MaxPenyaPerKill int64
	SkewSec      int64 // max |client_ts - now| accepted (anti-replay timestamp window)
	RateRPS      float64
	RateBurst    int
	MaxBodyBytes int64
}

func envStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("config: %s=%q is not an int, using default %d", key, v, def)
	}
	return def
}

func envInt64(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
		log.Printf("config: %s=%q is not an int, using default %d", key, v, def)
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseFloat(v, 64); err == nil {
			return n
		}
		log.Printf("config: %s=%q is not a float, using default %g", key, v, def)
	}
	return def
}

// loadConfig reads the environment. It fatals only on a missing secret (without it, signature
// verification is meaningless and every submission would be trivially forgeable).
func loadConfig() Config {
	c := Config{
		Secret:          os.Getenv("LB_SECRET"),
		AllowedHashes:   map[string]bool{},
		DBPath:          envStr("LB_DB_PATH", "./leaderboard.db"),
		Listen:          envStr("LB_LISTEN", ":8080"),
		MinSec:          envInt("LB_MIN_SEC", 300),
		MaxKPM:          envFloat("LB_MAX_KPM", 300),          // 5 kills/sec - generous ceiling
		MaxDensity:      envInt("LB_MAX_DENSITY", 300),        // a local pack this big is already implausible
		MaxPenyaPerKill: envInt64("LB_MAX_PENYA_PER_KILL", 20_000_000),
		SkewSec:         envInt64("LB_SKEW_SEC", 86400),       // +/- 1 day
		RateRPS:         envFloat("LB_RATE_RPS", 1),           // sustained per-IP request rate
		RateBurst:       envInt("LB_RATE_BURST", 10),
		MaxBodyBytes:    envInt64("LB_MAX_BODY_BYTES", 512*1024), // config blobs are a few KB; 512KB is plenty
	}
	if c.Secret == "" {
		log.Fatal("LB_SECRET is required (must match the client's LEADERBOARD_SECRET). Refusing to start.")
	}
	for _, h := range strings.Split(os.Getenv("LB_ALLOWED_HASHES"), ",") {
		h = strings.TrimSpace(h)
		if h != "" {
			c.AllowedHashes[h] = true
		}
	}
	if len(c.AllowedHashes) == 0 {
		log.Print("WARNING: LB_ALLOWED_HASHES is empty - accepting submissions from ANY build hash (dev mode). " +
			"Set it to your official BUILD_HASH value(s) in production.")
	}
	return c
}

// buildHashAllowed reports whether a submission's build hash passes the allowlist. Empty allowlist =
// dev mode (accept any); otherwise strict membership.
func (c Config) buildHashAllowed(h string) bool {
	if len(c.AllowedHashes) == 0 {
		return true
	}
	return c.AllowedHashes[h]
}
