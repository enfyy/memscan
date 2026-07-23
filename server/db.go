package main

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver (no cgo); registers the "sqlite" driver name
)

// DB wraps the SQLite connection + the prepared statements the handlers use.
type DB struct {
	sql *sql.DB
}

// errDuplicateNonce is returned by insertEntry when the nonce was already used (replay). The caller
// maps it to HTTP 409.
var errDuplicateNonce = errors.New("duplicate nonce")

const schema = `
CREATE TABLE IF NOT EXISTS entries (
	id              INTEGER PRIMARY KEY AUTOINCREMENT,
	name            TEXT    NOT NULL,
	build_hash      TEXT    NOT NULL,
	version         TEXT    NOT NULL,
	duration_sec    INTEGER NOT NULL,
	kills           INTEGER NOT NULL,
	penya           INTEGER NOT NULL,
	kpm             REAL    NOT NULL,
	max_density     INTEGER NOT NULL,
	unique_monsters INTEGER NOT NULL,
	monsters_json   TEXT    NOT NULL,
	config_blob     TEXT    NOT NULL,
	nonce           TEXT    NOT NULL UNIQUE,
	client_ts       INTEGER NOT NULL,
	created_at      INTEGER NOT NULL,
	ip_hash         TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_penya   ON entries(penya   DESC);
CREATE INDEX IF NOT EXISTS idx_kpm     ON entries(kpm     DESC);
CREATE INDEX IF NOT EXISTS idx_kills   ON entries(kills   DESC);
CREATE INDEX IF NOT EXISTS idx_monster ON entries(unique_monsters DESC);
CREATE INDEX IF NOT EXISTS idx_density ON entries(max_density DESC);
`

func openDB(path string) (*DB, error) {
	// _pragma busy_timeout so concurrent writers wait instead of erroring; WAL for read/write concurrency.
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(on)"
	sdb, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// modernc's driver is not fully concurrent for writes; a single open conn keeps writes serialized.
	sdb.SetMaxOpenConns(1)
	if _, err := sdb.Exec(schema); err != nil {
		sdb.Close()
		return nil, err
	}
	return &DB{sql: sdb}, nil
}

func (db *DB) Close() error { return db.sql.Close() }

// Row is one stored entry as served on the board (config blob + monster json excluded).
type Row struct {
	ID             int64   `json:"id"`
	Name           string  `json:"name"`
	BuildHash      string  `json:"build_hash"`
	Kills          int     `json:"kills"`
	Penya          int64   `json:"penya"`
	KPM            float64 `json:"kpm"`
	MaxDensity     int     `json:"max_density"`
	DurationSec    int     `json:"duration_sec"`
	UniqueMonsters int     `json:"unique_monsters"`
}

// insertEntry stores a verified submission and returns its new id. A UNIQUE-violation on nonce maps to
// errDuplicateNonce (the DB layer is the last line of anti-replay defense, race-safe under concurrency).
func (db *DB) insertEntry(p *Payload, kpm float64, uniqueMon int, monstersJSON, ipHash string) (int64, error) {
	res, err := db.sql.Exec(
		`INSERT INTO entries
		 (name, build_hash, version, duration_sec, kills, penya, kpm, max_density,
		  unique_monsters, monsters_json, config_blob, nonce, client_ts, created_at, ip_hash)
		 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		p.Name, p.BuildHash, p.Version, p.DurationSec, p.Kills, p.Penya, kpm, p.MaxDensity,
		uniqueMon, monstersJSON, p.Config, p.Nonce, p.Ts, time.Now().Unix(), ipHash,
	)
	if err != nil {
		if isUniqueViolation(err) {
			return 0, errDuplicateNonce
		}
		return 0, err
	}
	return res.LastInsertId()
}

// sortColumn maps a public sort key to a real (indexed) column. Unknown keys fall back to penya.
func sortColumn(sort string) string {
	switch sort {
	case "kpm":
		return "kpm"
	case "kills":
		return "kills"
	case "monsters":
		return "unique_monsters"
	case "density":
		return "max_density"
	default: // "penya" and anything unrecognized
		return "penya"
	}
}

// topEntries returns the highest-ranked rows by the given sort key. The column is chosen from a fixed
// whitelist (sortColumn) so `sort` is never interpolated as raw SQL.
func (db *DB) topEntries(sort string, limit int) ([]Row, error) {
	col := sortColumn(sort)
	q := `SELECT id, name, build_hash, kills, penya, kpm, max_density, duration_sec, unique_monsters
	      FROM entries ORDER BY ` + col + ` DESC, id ASC LIMIT ?`
	rows, err := db.sql.Query(q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Row, 0, limit)
	for rows.Next() {
		var r Row
		if err := rows.Scan(&r.ID, &r.Name, &r.BuildHash, &r.Kills, &r.Penya, &r.KPM,
			&r.MaxDensity, &r.DurationSec, &r.UniqueMonsters); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// entryConfig returns the stored flyff.cfg blob for an entry, or ok=false if the id is unknown.
func (db *DB) entryConfig(id int64) (cfg string, ok bool, err error) {
	err = db.sql.QueryRow(`SELECT config_blob FROM entries WHERE id = ?`, id).Scan(&cfg)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return cfg, true, nil
}

// isUniqueViolation detects a SQLite UNIQUE-constraint error without importing the driver's error type
// (modernc surfaces it in the message: "constraint failed: UNIQUE ...", code 2067/1555).
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	m := strings.ToLower(err.Error())
	return strings.Contains(m, "unique") && strings.Contains(m, "constraint")
}
