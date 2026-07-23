package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// ===========================================================================
// Signature verification. The canonical string below MUST match the client's lb_canonical
// (src/flyff/leaderboard.odin) byte-for-byte, or every real submission would be rejected.
//
// Client format (Odin fmt.tprintf):
//   "%s\n%s\n%d\n%d\n%d\n%d\n%s\n%d\n%s\n%s"
//   name, build_hash, duration_sec, kills, penya, max_density, nonce, ts, sha256hex(config), monsters
//
// monsters is the sorted-by-name join "name:count,name:count,..." (see monstersCanonical). Both ends
// sort with a plain byte-wise ascending string sort (Odin's slice.sort over []string == Go's sort.Strings).
// ===========================================================================

// monstersCanonical renders the monster map as sorted "name:count,name:count". Order is defined so the
// client and server produce the identical string from the same (unordered) map.
func monstersCanonical(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%s:%d", k, m[k])
	}
	return b.String()
}

// canonicalString rebuilds the exact string the client signed.
func canonicalString(p *Payload) string {
	sum := sha256.Sum256([]byte(p.Config))
	cfgHex := hex.EncodeToString(sum[:])
	mon := monstersCanonical(p.Monsters)
	return fmt.Sprintf("%s\n%s\n%d\n%d\n%d\n%d\n%s\n%d\n%s\n%s",
		p.Name, p.BuildHash, p.DurationSec, p.Kills, p.Penya, p.MaxDensity, p.Nonce, p.Ts, cfgHex, mon)
}

// signHex computes hex(HMAC-SHA256(secret, canonical)). Matches the client's lb_sign.
func signHex(secret, canonical string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(canonical))
	return hex.EncodeToString(mac.Sum(nil))
}

// verifySignature recomputes the signature and compares it to the client's in constant time.
func verifySignature(secret string, p *Payload) bool {
	expected := signHex(secret, canonicalString(p))
	// hmac.Equal is constant-time; compare the raw hex strings (both lowercase hex of the same length).
	return hmac.Equal([]byte(expected), []byte(strings.ToLower(strings.TrimSpace(p.Sig))))
}
