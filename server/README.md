# memscan leaderboard backend

A small self-hosted Go service that stores timed farm-run submissions from the memscan client and
serves a sortable leaderboard. Single static binary, pure-Go SQLite (no cgo), standard-library HTTP.

## What it does

- `POST /api/v1/submit` - verifies a signed run and stores it.
- `GET  /api/v1/leaderboard?sort=penya|kpm|kills|monsters|density&limit=100` - ranked JSON rows.
- `GET  /api/v1/entry/{id}/config` - that entry's full `flyff.cfg` blob as `text/plain`.
- `GET  /healthz` - liveness probe.

## Build

Requires Go 1.22+.

```sh
cd server
go mod tidy      # fetches modernc.org/sqlite + golang.org/x/time and writes go.sum
go build -o memscan-leaderboard .
```

The `go.mod` lists only the two direct dependencies on purpose; `go mod tidy` pins the (many) indirect
`modernc.org/*` modules into `go.sum`.

## Configure (environment variables)

| Var | Default | Meaning |
|-----|---------|---------|
| `LB_SECRET` | *(required)* | HMAC secret. **Must equal the client's `LEADERBOARD_SECRET`** (`src/flyff/leaderboard_secret.odin`). The server refuses to start without it. |
| `LB_ALLOWED_HASHES` | *(empty)* | Comma-separated allowlist of official `BUILD_HASH` values. **Empty = dev mode: accept any build** (with a loud warning). Set it in production. |
| `LB_DB_PATH` | `./leaderboard.db` | SQLite file path. |
| `LB_LISTEN` | `:8080` | Listen address. |
| `LB_MIN_SEC` | `600` | Minimum accepted `duration_sec` (the 10-minute rule). Lower **only** for local testing. |
| `LB_MAX_KPM` | `300` | Reject runs whose kills/min exceed this. |
| `LB_MAX_DENSITY` | `300` | Reject implausible peak density. |
| `LB_MAX_PENYA_PER_KILL` | `20000000` | Reject implausible penya/kill. |
| `LB_SKEW_SEC` | `86400` | Max `|client_ts - now|` accepted (anti-replay window). |
| `LB_RATE_RPS` | `1` | Sustained per-IP request rate. |
| `LB_RATE_BURST` | `10` | Per-IP burst. |
| `LB_MAX_BODY_BYTES` | `524288` | Request body cap (512 KB). |

### Finding your BUILD_HASH

`build.bat` prints it every build (`build hash: <hex> (NN source files)`), and it is also written to
`src/build_hash.g.odin`. Put that value in `LB_ALLOWED_HASHES` on the server. Only a build whose source
(including `leaderboard_secret.odin`) hashes to an allowlisted value is accepted - see the security note.

## Run

Local dev (accept any build, 60-second minimum so you don't have to farm 10 minutes to test):

```sh
LB_SECRET=test LB_MIN_SEC=60 LB_DB_PATH=./lb.db LB_LISTEN=:8080 ./memscan-leaderboard
```

Production (behind TLS, strict allowlist, real secret):

```sh
LB_SECRET='<the real LEADERBOARD_SECRET>' \
LB_ALLOWED_HASHES='5b6c153e2c47,<next official hash>' \
LB_MIN_SEC=600 LB_DB_PATH=/var/lib/memscan-lb/lb.db LB_LISTEN=127.0.0.1:8080 \
./memscan-leaderboard
```

Terminate TLS at nginx/Caddy and proxy to the listen address. The service reads `X-Forwarded-For` for
the client IP (rate limiting / audit), so only expose it through a trusted proxy. See the systemd unit
`memscan-leaderboard.service`.

## Client setup

In memscan (after attaching): `set leaderboard_url https://your-host/`  -> the "Leaderboards..." button
appears at the bottom of the radar sidebar, and the `leaderboard` CLI subcommands go live. `status full`
shows the LEADERBOARD section.

## Verify end-to-end

With the dev server running (`LB_SECRET=test LB_MIN_SEC=60`):

- Health: `curl -s localhost:8080/healthz` -> `ok`
- A correctly-signed submit returns `{"id":1}`. A wrong `sig` or a disallowed `build_hash` -> `403`. A
  replayed `nonce` -> `409`. A `duration_sec < LB_MIN_SEC` -> `422`.
- `curl -s 'localhost:8080/api/v1/leaderboard?sort=penya'` returns the row.
- `curl -s localhost:8080/api/v1/entry/1/config` returns the stored `flyff.cfg` text.

(The client's `leaderboard submit`/`top`/`getcfg` exercise the same paths; use the dev `LB_MIN_SEC=60`
so a short recording clears the gate.)

## Security / cheat-proofing (stated honestly)

Layered defense-in-depth, each raising the bar:

1. **Build-hash allowlist** - only builds whose source (including the compiled-in secret file) hashes to
   an official value are accepted.
2. **HMAC-SHA256 signing** with a shared secret compiled into official builds - blocks naive scripted
   submissions that don't know the secret.
3. **Server-side plausibility** - hard minimum duration, kpm/penya/density caps, a monster-tally check,
   anti-replay (`nonce UNIQUE` + timestamp skew).
4. **Rate limiting** - per-IP token bucket + a global ceiling + a request-body cap.

**Honest limitation:** the stats originate in a memory-reading tool, and the shared secret is extractable
by reversing the distributed binary. A determined, skilled attacker can still forge a submission. This
design makes casual rigging hard and keeps the server robust - it is **not** an anti-cheat guarantee.

### Rotating the secret

The `LEADERBOARD_SECRET` in `src/flyff/leaderboard_secret.odin` ships as a placeholder. For a real
deployment: replace it with a fresh random value, set the **same** value as `LB_SECRET` on the server,
rebuild, and add the new build's `BUILD_HASH` to `LB_ALLOWED_HASHES`. Keep the real value out of the
public repo (e.g. `git update-index --skip-worktree src/flyff/leaderboard_secret.odin` after swapping it
locally).
