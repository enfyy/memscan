package flyff

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import curl "vendor:curl"

import "../engine"

// ===========================================================================
// Leaderboards: snapshot a timed farm run + submit it to a self-hosted backend.
//
// A "run" is an explicit Start/Stop recording span (lb_run on the Session). While active it
// accumulates the farm stats we submit: kills, penya collected, peak local density, and the set
// of distinct monster names farmed. The kill sites in autofarm.odin call lb_record_kill; the pick
// sites (target.odin / auto_commit_pick) call lb_note_commit so a kill's monster name + pack size
// are known even after the object is freed. `leaderboard submit <name>` finalizes the span, builds
// an HMAC-signed JSON payload (including the full flyff.cfg text so others can download the setup),
// and POSTs it to leaderboard_url on a worker thread that never holds exec_mutex during the request.
//
// Cheat-proofing is layered and honest (see leaderboard_secret.odin + server/README.md): the build
// hash gates which builds the server accepts, the HMAC blocks unsigned submissions, and the server
// re-checks plausibility (>=5 min, rate caps) + rate-limits. A memory tool's self-reported stats
// are still spoofable by a determined attacker - this raises the bar, it is not anti-cheat.
// ===========================================================================

LB_MIN_SEC :: 300 // a submission must cover at least this many seconds - 5 min (server enforces this too)
LB_USER_AGENT :: "memscan-leaderboard/1.0"
LB_HTTP_TIMEOUT_MS :: 15000
LB_CONNECT_TIMEOUT_MS :: 8000

// The sortable board columns. Index 0 is the default. The string is the backend `sort` query value;
// kept in sync with the Go server's allowed sorts and the radar dialog's sort toggle.
LB_SORTS := [5]string{"penya", "kpm", "kills", "monsters", "density"}

// ===========================================================================
// Types
// ===========================================================================

// The live recording span. Stats accrue while active; stop freezes the endpoints so the submitted
// numbers don't keep drifting (penya_total keeps growing after stop; kills don't). names owns cloned
// key strings (freed in lb_names_clear). Reset on attach, freed on close (module.odin).
Leaderboard_Run :: struct {
	active:       bool,
	start_ns:     i64, // time.now()._nsec at start
	end_ns:       i64, // time.now()._nsec at stop (0 while active / never run)
	penya:        i64, // penya collected during the span, KILL-PAIRED only (see lb_note_penya_gain)
	last_kill_ns: i64, // time of the most recent confirmed kill (the penya-gain pairing window anchor)
	kills:        int,
	max_density:  int,
	names:        map[string]int, // distinct monster name -> kills of it
	// A run gets ONE identity: nonce is drawn at `leaderboard start` (not per submit call), so re-submitting
	// the same run reuses the same nonce and the server's UNIQUE-nonce dedup rejects it (409). submitted
	// guards the local re-attempt so you don't even round-trip. Both reset by the next `leaderboard start`.
	nonce:        [16]u8, // random per-run id, hex-encoded into the payload
	submitted:    bool, // this run already made it onto the board
}

// A penya gain is only credited to a span if it lands within this window after a kill (a loot pickup).
// Gains outside it (idle Perin conversions, sales, trades, quest rewards) are not farming income.
LB_PENYA_KILL_WINDOW_NS :: i64(10_000_000_000) // 10s

// One leaderboard row as shown in the dialog / printed by `leaderboard top`. Fixed-size name/build
// buffers (not heap strings) so a Session.lb_board row is a pure value copy - the radar snapshots the
// whole slice under exec_mutex with slice.clone and draws it lock-free, no string aliasing to race.
Lb_Row :: struct {
	id:          int,
	name:        [24]u8, // NUL-terminated
	build:       [16]u8, // NUL-terminated (build hash prefix)
	kills:       int,
	penya:       i64,
	kpm:         f32,
	max_density: int,
	dur_sec:     int,
	monsters:    int, // distinct monster count
}

// The submission payload. Marshaled to JSON with json.marshal (field names become the JSON keys, so
// they must match the Go server's struct). sig is HMAC-SHA256 over the canonical string (lb_canonical).
Lb_Payload :: struct {
	name:         string,
	build_hash:   string,
	version:      string,
	duration_sec: int,
	kills:        int,
	penya:        i64,
	max_density:  int,
	monsters:     map[string]int,
	config:       string, // full flyff.cfg text (downloadable by others)
	nonce:        string, // 16 random bytes, hex (anti-replay)
	ts:           i64, // client unix seconds (anti-replay skew window)
	sig:          string, // hex HMAC-SHA256 over lb_canonical(...)
}

// Server response shapes (a subset of the fields; unknown keys are ignored by json.unmarshal).
Lb_Submit_Resp :: struct {
	id:    int,
	error: string,
}
Lb_Row_Json :: struct {
	id:              int,
	name:            string,
	build_hash:      string,
	kills:           int,
	penya:           i64,
	kpm:             f64,
	max_density:     int,
	duration_sec:    int,
	unique_monsters: int,
}
Lb_Board_Resp :: struct {
	entries: []Lb_Row_Json,
	error:   string,
}

// ===========================================================================
// Global state
// ===========================================================================

@(private = "file")
lb_curl_once: sync.Once

@(private = "file")
lb_curl_init :: proc() {
	sync.once_do(&lb_curl_once, proc() {curl.global_init(curl.GLOBAL_DEFAULT)})
}

// ===========================================================================
// Small buffer / hex helpers
// ===========================================================================

// Lowercase hex of a byte slice (temp-allocated).
lb_hex :: proc(b: []byte, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for x in b {
		fmt.sbprintf(&sb, "%02x", x)
	}
	return strings.to_string(sb)
}

// ===========================================================================
// Recording accumulator (called from the CLI + the auto kill/pick sites)
// ===========================================================================

// Free the cloned monster-name keys and empty the map (safe on a nil map).
lb_names_clear :: proc(r: ^Leaderboard_Run) {
	if r.names == nil {
		return
	}
	for k in r.names {
		delete(k)
	}
	clear(&r.names)
}

// Fully release the run's owned memory (on_close).
lb_run_free :: proc(s: ^Session) {
	lb_names_clear(&s.lb_run)
	delete(s.lb_run.names)
	s.lb_run = {}
}

// Reset the run to idle (on_attach: a new process starts a fresh span baseline).
lb_run_reset :: proc(s: ^Session) {
	lb_names_clear(&s.lb_run)
	if s.lb_run.names == nil {
		s.lb_run.names = make(map[string]int)
	}
	s.lb_run.active = false
	s.lb_run.start_ns = 0
	s.lb_run.end_ns = 0
	s.lb_run.penya = 0
	s.lb_run.last_kill_ns = 0
	s.lb_run.kills = 0
	s.lb_run.max_density = 0
	s.lb_run.nonce = {}
	s.lb_run.submitted = false
	s.lb_cur_name[0] = 0
	s.lb_cur_pack = 0
}

// Begin a recording span (clears any prior data). Draws a fresh per-run nonce so this run can be submitted
// exactly once (the server dedups on it).
lb_start :: proc(s: ^Session) {
	lb_names_clear(&s.lb_run)
	if s.lb_run.names == nil {
		s.lb_run.names = make(map[string]int)
	}
	now := time.now()._nsec
	s.lb_run.active = true
	s.lb_run.start_ns = now
	s.lb_run.end_ns = 0
	s.lb_run.penya = 0
	s.lb_run.last_kill_ns = 0
	s.lb_run.kills = 0
	s.lb_run.max_density = 0
	crypto.rand_bytes(s.lb_run.nonce[:])
	s.lb_run.submitted = false
	s.lb_cur_name[0] = 0
	s.lb_cur_pack = 0
}

// Freeze the span (keeps the data for inspection / submit). penya stops accruing because gains are only
// credited while active, so no endpoint capture is needed.
lb_stop :: proc(s: ^Session) {
	if !s.lb_run.active {
		return
	}
	s.lb_run.active = false
	s.lb_run.end_ns = time.now()._nsec
}

lb_elapsed_sec :: proc(s: ^Session) -> int {
	if s.lb_run.start_ns == 0 {
		return 0
	}
	end := s.lb_run.active ? time.now()._nsec : s.lb_run.end_ns
	el := end - s.lb_run.start_ns
	if el < 0 {
		el = 0
	}
	return int(el / 1_000_000_000)
}

// Penya collected across the span - only the kill-paired total (see lb_note_penya_gain), NOT the raw
// penya_total delta, so Perin conversions / sales / trades never inflate a submission.
lb_penya :: proc(s: ^Session) -> i64 {
	return s.lb_run.penya
}

// Credit a penya gain to the active span IF it's plausibly a kill drop: it must land within
// LB_PENYA_KILL_WINDOW_NS of a confirmed kill (a loot pickup) AND not exceed layout.lb_penya_cap (a single
// jump bigger than that is a Perin conversion / trade / quest reward, not a drop). Called from penya_tick.
lb_note_penya_gain :: proc(s: ^Session, gain: i64, now: i64) {
	if !s.lb_run.active || gain <= 0 {
		return
	}
	if now - s.lb_run.last_kill_ns > LB_PENYA_KILL_WINDOW_NS {
		return // no recent kill - not farming income
	}
	pcap := s.layout.lb_penya_cap
	if pcap > 0 && gain > pcap {
		return // too big to be a single drop (e.g. a 100M Perin)
	}
	s.lb_run.penya += gain
}

lb_kpm :: proc(s: ^Session) -> f64 {
	el := lb_elapsed_sec(s)
	if el <= 0 {
		return 0
	}
	return f64(s.lb_run.kills) * 60.0 / f64(el)
}

// Carry the just-committed auto target's name + local pack size forward, so the kill site can attribute
// them after the object may be freed. Cheap + gated on an active recording (zero cost when not recording).
lb_note_commit :: proc(s: ^Session, obj: uintptr, pack: int) {
	if !s.lb_run.active {
		return
	}
	s.lb_cur_pack = pack
	if nm, ok := engine.read_obj_name(s.proc_info.handle, s.ptr_size, obj, s.layout.name_off); ok {
		panel_buf_set(s.lb_cur_name[:], nm)
	} else {
		s.lb_cur_name[0] = 0
	}
}

// Attribute one confirmed kill to the active span. Called from both auto kill sites (autofarm.odin).
lb_record_kill :: proc(s: ^Session, killed_obj: uintptr) {
	if !s.lb_run.active {
		return
	}
	s.lb_run.kills += 1
	s.lb_run.last_kill_ns = time.now()._nsec // open the penya-pairing window (lb_note_penya_gain)
	if s.lb_run.max_density < s.lb_cur_pack {
		s.lb_run.max_density = s.lb_cur_pack
	}
	name := panel_buf_str(s.lb_cur_name[:])
	if name == "" {
		// The committed name is missing (e.g. recording started mid-fight) - best-effort live read.
		if nm, ok := engine.read_obj_name(s.proc_info.handle, s.ptr_size, killed_obj, s.layout.name_off); ok {
			name = nm
		}
	}
	if name == "" {
		name = "?"
	}
	if s.lb_run.names == nil {
		s.lb_run.names = make(map[string]int)
	}
	if _, ok := s.lb_run.names[name]; ok {
		s.lb_run.names[name] += 1
	} else {
		s.lb_run.names[strings.clone(name)] = 1 // own the key (name may be temp/stack)
	}
}

// ===========================================================================
// Status line (written by the async workers, read by the CLI + radar)
// ===========================================================================

lb_set_status :: proc(s: ^Session, msg: string) {
	panel_buf_set(s.lb_status_buf[:], msg)
}
lb_status_str :: proc(s: ^Session) -> string {
	return panel_buf_str(s.lb_status_buf[:])
}

// ===========================================================================
// Signing (HMAC-SHA256 over a canonical string - MUST match the Go server byte-for-byte)
// ===========================================================================

// Sorted "name:count,name:count" over the monster map (map order is undefined; both ends sort).
lb_monsters_canonical :: proc(m: map[string]int, allocator := context.temp_allocator) -> string {
	keys := make([dynamic]string, 0, len(m), context.temp_allocator)
	for k in m {
		append(&keys, k)
	}
	slice.sort(keys[:])
	sb := strings.builder_make(allocator)
	for k, i in keys {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, "%s:%d", k, m[k])
	}
	return strings.to_string(sb)
}

// The canonical string the signature covers. Field order + separators are a wire contract with the
// server (see server/security.go). config is folded in as its SHA-256 so a huge blob doesn't bloat it.
lb_canonical :: proc(name, build: string, dur, kills: int, penya: i64, maxd: int, nonce: string, ts: i64, config: string, monsters: map[string]int) -> string {
	cfg_digest := hash.hash_string(hash.Algorithm.SHA256, config, context.temp_allocator)
	cfg_hex := lb_hex(cfg_digest)
	mon := lb_monsters_canonical(monsters)
	return fmt.tprintf(
		"%s\n%s\n%d\n%d\n%d\n%d\n%s\n%d\n%s\n%s",
		name, build, dur, kills, penya, maxd, nonce, ts, cfg_hex, mon,
	)
}

// hex(HMAC-SHA256(secret, canonical)).
lb_sign :: proc(canonical: string) -> string {
	tag: [32]byte // SHA-256 tag size
	hmac.sum(hash.Algorithm.SHA256, tag[:], transmute([]byte)canonical, transmute([]byte)string(LEADERBOARD_SECRET))
	return lb_hex(tag[:])
}

// ===========================================================================
// HTTP (vendor:curl; HTTPS via the statically-linked libcurl) - runs OFF exec_mutex on a worker.
// ===========================================================================

// curl write callback: append the response bytes into a strings.Builder handed via WRITEDATA. The
// Builder's dynamic buffer carries its own allocator, so appends don't need context.allocator - but we
// set a valid context anyway since this is a foreign "c" callback with no Odin context of its own.
@(private = "file")
lb_write_cb :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, out: rawptr) -> c.size_t {
	context = runtime.default_context()
	n := int(size * nitems)
	sink := cast(^strings.Builder)out
	strings.write_bytes(sink, buffer[:n])
	return c.size_t(n)
}

// Perform one HTTP request. method is "GET" or "POST"; body is the POST payload ("" for GET). Returns
// the HTTP status code, the response body (heap-allocated in `allocator`), and ok=false on a transport
// error (in which case `resp` holds a human-readable curl error).
lb_http :: proc(method: string, url: string, body: string, allocator := context.allocator) -> (http_code: int, resp: string, ok: bool) {
	lb_curl_init()
	h := curl.easy_init()
	if h == nil {
		return 0, "curl init failed", false
	}
	defer curl.easy_cleanup(h)

	cu := strings.clone_to_cstring(url, context.allocator)
	defer delete(cu)
	curl.easy_setopt(h, curl.option.URL, cu)
	curl.easy_setopt(h, curl.option.TIMEOUT_MS, c.long(LB_HTTP_TIMEOUT_MS))
	curl.easy_setopt(h, curl.option.CONNECTTIMEOUT_MS, c.long(LB_CONNECT_TIMEOUT_MS))
	curl.easy_setopt(h, curl.option.USERAGENT, cstring(LB_USER_AGENT))

	sink := strings.builder_make()
	defer strings.builder_destroy(&sink)
	curl.easy_setopt(h, curl.option.WRITEFUNCTION, curl.write_callback(lb_write_cb))
	curl.easy_setopt(h, curl.option.WRITEDATA, &sink)

	hdr: ^curl.slist = nil
	bc: cstring = nil
	if method == "POST" {
		hdr = curl.slist_append(hdr, cstring("Content-Type: application/json"))
		curl.easy_setopt(h, curl.option.HTTPHEADER, hdr)
		bc = strings.clone_to_cstring(body, context.allocator)
		curl.easy_setopt(h, curl.option.POSTFIELDS, bc) // not copied by curl; kept alive until perform returns
		curl.easy_setopt(h, curl.option.POSTFIELDSIZE, c.long(len(body)))
	}

	rc := curl.easy_perform(h)
	if hdr != nil {
		curl.slist_free_all(hdr)
	}
	if bc != nil {
		delete(bc)
	}
	if rc != .E_OK {
		return 0, strings.clone(fmt.tprintf("network error: %s", curl.easy_strerror(rc)), allocator), false
	}
	code: c.long = 0
	curl.easy_getinfo(h, curl.INFO.RESPONSE_CODE, &code)
	return int(code), strings.clone(strings.to_string(sink), allocator), true
}

// ===========================================================================
// Async jobs (the network worker; never holds exec_mutex during curl)
// ===========================================================================

Lb_Job_Kind :: enum {
	Submit,
	Fetch,
	Getcfg,
}

Lb_Job :: struct {
	session: ^Session,
	kind:    Lb_Job_Kind,
	url:     string, // heap-owned
	body:    string, // heap-owned (POST body; "" for GET)
	path:    string, // heap-owned (getcfg output path)
	id:      int, // getcfg entry id (for messages)
	sort:    int, // fetch: which LB_SORTS index this board reflects
	verbose: bool, // CLI-initiated -> print results to the console when done
}

// Spawn the worker. Called under exec_mutex (from cli_leaderboard); the worker itself takes the lock
// only to write results back, and does the blocking curl call in between with the lock released.
lb_spawn :: proc(job: ^Lb_Job) {
	thread.create_and_start_with_data(job, lb_worker, nil, .Normal, true) // self_cleanup: fire-and-forget
}

@(private = "file")
lb_worker :: proc(data: rawptr) {
	// All status messages + parsed JSON below are temp-allocated; free them in one shot on return.
	// The only heap string here is `resp` from lb_http (freed by its own `defer delete(resp)`). Nothing
	// escapes the worker: lb_set_status copies the bytes into a fixed Session buffer under the lock, and
	// every verbose print happens before this proc returns.
	defer free_all(context.temp_allocator)
	j := cast(^Lb_Job)data
	s := j.session
	switch j.kind {
	case .Submit:
		code, resp, ok := lb_http("POST", j.url, j.body)
		defer delete(resp)
		msg: string
		if !ok {
			msg = resp
		} else if code == 200 || code == 201 {
			r: Lb_Submit_Resp
			if json.unmarshal(transmute([]byte)resp, &r, allocator = context.temp_allocator) == nil && r.id > 0 {
				msg = fmt.tprintf("submitted #%d", r.id)
			} else {
				msg = "submitted"
			}
		} else {
			msg = lb_reject_msg(code, resp)
		}
		sync.mutex_lock(&s.exec_mutex)
		lb_set_status(s, msg)
		if !ok {
			s.lb_run.submitted = false // transport error: the run never reached the server, so allow a retry
		}
		s.lb_net_busy = false
		sync.mutex_unlock(&s.exec_mutex)
		if j.verbose {
			fmt.printf("\n[leaderboard] %s\nmemscan> ", msg)
		}

	case .Fetch:
		code, resp, ok := lb_http("GET", j.url, "")
		defer delete(resp)
		if !ok || code != 200 {
			msg := ok ? lb_reject_msg(code, resp) : resp
			sync.mutex_lock(&s.exec_mutex)
			lb_set_status(s, msg)
			s.lb_net_busy = false
			sync.mutex_unlock(&s.exec_mutex)
			if j.verbose {fmt.printf("\n[leaderboard] %s\nmemscan> ", msg)}
			break
		}
		board: Lb_Board_Resp
		if json.unmarshal(transmute([]byte)resp, &board, allocator = context.temp_allocator) != nil {
			sync.mutex_lock(&s.exec_mutex)
			lb_set_status(s, "bad server response")
			s.lb_net_busy = false
			sync.mutex_unlock(&s.exec_mutex)
			if j.verbose {fmt.printf("\n[leaderboard] bad server response\nmemscan> ")}
			break
		}
		sync.mutex_lock(&s.exec_mutex)
		clear(&s.lb_board)
		for e in board.entries {
			row := Lb_Row {
				id          = e.id,
				kills       = e.kills,
				penya       = e.penya,
				kpm         = f32(e.kpm),
				max_density = e.max_density,
				dur_sec     = e.duration_sec,
				monsters    = e.unique_monsters,
			}
			panel_buf_set(row.name[:], e.name)
			panel_buf_set(row.build[:], e.build_hash)
			append(&s.lb_board, row)
		}
		s.lb_board_sort = j.sort
		n := len(s.lb_board)
		lb_set_status(s, fmt.tprintf("loaded %d entries", n))
		rows := slice.clone(s.lb_board[:], context.temp_allocator) if j.verbose else nil
		s.lb_net_busy = false
		sync.mutex_unlock(&s.exec_mutex)
		if j.verbose {
			lb_print_board(rows, j.sort)
		}

	case .Getcfg:
		code, resp, ok := lb_http("GET", j.url, "")
		defer delete(resp)
		msg: string
		if !ok {
			msg = resp
		} else if code != 200 {
			msg = lb_reject_msg(code, resp)
		} else {
			werr := os.write_entire_file(j.path, transmute([]byte)resp)
			msg = werr == nil ? fmt.tprintf("saved config #%d -> %s", j.id, j.path) : fmt.tprintf("write failed: %s", j.path)
		}
		sync.mutex_lock(&s.exec_mutex)
		lb_set_status(s, msg)
		s.lb_net_busy = false
		sync.mutex_unlock(&s.exec_mutex)
		if j.verbose {
			fmt.printf("\n[leaderboard] %s\nmemscan> ", msg)
		}
	}
	// free the job (its heap-owned strings were allocated by the CLI spawn helpers)
	delete(j.url)
	delete(j.body)
	delete(j.path)
	free(j)
}

// Human-readable rejection for a non-2xx HTTP response, pulling the server's {"error":...} if present.
lb_reject_msg :: proc(code: int, body: string, allocator := context.temp_allocator) -> string {
	r: Lb_Submit_Resp
	if json.unmarshal(transmute([]byte)body, &r) == nil && r.error != "" {
		return fmt.aprintf("rejected (HTTP %d): %s", code, r.error, allocator = allocator)
	}
	return fmt.aprintf("rejected (HTTP %d)", code, allocator = allocator)
}

// Print a fetched board as a console table (CLI `leaderboard top`).
lb_print_board :: proc(rows: []Lb_Row, sort: int) {
	sname := sort >= 0 && sort < len(LB_SORTS) ? LB_SORTS[sort] : "penya"
	fmt.printf("\n=== leaderboard (by %s) ===\n", sname)
	if len(rows) == 0 {
		fmt.printf("  (no entries)\nmemscan> ")
		return
	}
	fmt.printf("  %-3s %-16s %8s %10s %6s %5s %6s %-12s\n", "#", "name", "kills", "penya", "kpm", "dens", "mobs", "time")
	for i in 0 ..< len(rows) {
		r := &rows[i] // pointer: fixed-array fields aren't sliceable off a for-copy
		nm := panel_buf_str(r.name[:])
		fmt.printf(
			"  %-3d %-16s %8d %10d %6.1f %5d %6d %-12s\n",
			i + 1, nm, r.kills, r.penya, r.kpm, r.max_density, r.monsters, fmt_elapsed(i64(r.dur_sec) * 1_000_000_000),
		)
	}
	fmt.printf("memscan> ")
}

// ===========================================================================
// Config sharing (upload/download the FARMING SETUP only, never the memory layout)
// ===========================================================================

// The flyff.cfg keys that are safe + useful to share on the leaderboard: pure behavior/tuning. Everything
// else in the file is per-game-version memory layout (offsets/RVAs) or private (leaderboard_url). Sharing
// those is useless (a downloader has their own from `setup`) AND dangerous - bad offsets/RVAs drive memory
// writes + remote calls, so loading an untrusted full config could crash or corrupt the downloader's game.
// flyff_load_cfg only assigns keys it actually finds, so a downloader who applies a behavior-only config
// keeps THEIR offsets and just adopts the farming setup. Keep this in sync with the tunables in flyff_save_cfg.
@(private = "file")
LB_SHAREABLE_KEYS := [?]string {
	"attack_range",
	"radar_range",
	"density_on",
	"density_weight",
	"density_min_gain",
	"density_max_detour",
	"density_hue_on",
	"preselect_on",
	"lookalive_on",
	"la_hold_min",
	"la_hold_max",
	"la_jump_min",
	"la_jump_max",
	"la_jump_chance",
	"la_hesitate_on",
	"la_jump_on",
	"la_step_on",
	"la_maxrange_on",
	"la_step_chance",
	"la_step_spread",
	"la_max_range",
	"reach_gate_on",
	"hunt_on",
	"sfx_on",
	"fx_laser_on",
	"trail_on",
	"trail_len",
	"trail_fade",
	"hillshade_on",
	"hillshade_z",
	"hillshade_light",
	"lb_penya_cap",
}

// Filter a raw flyff.cfg down to only the shareable behavior keys (LB_SHAREABLE_KEYS). Default-DENY: an
// unrecognized key is dropped, so a newly-added offset key can never leak in by accident. Temp-allocated.
lb_shareable_config :: proc(cfg: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for line in strings.split(cfg, "\n", context.temp_allocator) {
		t := strings.trim_space(line) // also strips a trailing '\r' on CRLF files
		if t == "" || t[0] == '#' {
			continue
		}
		eq := strings.index_byte(t, '=')
		if eq <= 0 {
			continue
		}
		key := strings.trim_space(t[:eq])
		for k in LB_SHAREABLE_KEYS {
			if k == key {
				fmt.sbprintfln(&b, "%s", t)
				break
			}
		}
	}
	return strings.to_string(b)
}

// ===========================================================================
// Payload assembly (runs under exec_mutex in cli_leaderboard)
// ===========================================================================

lb_build_payload :: proc(s: ^Session, name: string) -> (body: string, ok: bool) {
	cfg_path := flyff_cfg_path(context.temp_allocator)
	cfg := ""
	if data, rerr := os.read_entire_file(cfg_path, context.temp_allocator); rerr == nil {
		cfg = lb_shareable_config(string(data)) // upload the farming setup only - never the memory offsets
	}
	// Per-RUN nonce (set at lb_start), NOT a fresh one per submit call - that's what makes a run submit once:
	// re-submitting reuses this nonce and the server rejects the duplicate.
	nonce := lb_hex(s.lb_run.nonce[:])
	ts := time.now()._nsec / 1_000_000_000
	dur := lb_elapsed_sec(s)
	kills := s.lb_run.kills
	penya := lb_penya(s)
	maxd := s.lb_run.max_density
	build := s.eng.app_build_hash
	ver := s.eng.app_version

	canon := lb_canonical(name, build, dur, kills, penya, maxd, nonce, ts, cfg, s.lb_run.names)
	sig := lb_sign(canon)

	payload := Lb_Payload {
		name         = name,
		build_hash   = build,
		version      = ver,
		duration_sec = dur,
		kills        = kills,
		penya        = penya,
		max_density  = maxd,
		monsters     = s.lb_run.names,
		config       = cfg,
		nonce        = nonce,
		ts           = ts,
		sig          = sig,
	}
	data, merr := json.marshal(payload, {}, context.temp_allocator)
	if merr != nil {
		return "", false
	}
	return strings.clone(string(data)), true // heap; the worker frees it
}

// ===========================================================================
// URL helpers
// ===========================================================================

// (url, configured?) - the gate for the radar button + the `leaderboard` network subcommands.
lb_url :: proc(s: ^Session) -> (string, bool) {
	u := s.layout.leaderboard_url
	return u, u != ""
}

// Join the base URL with a path (trims a trailing '/' on the base so we don't double it).
lb_join :: proc(base, path: string, allocator := context.allocator) -> string {
	b := base
	for len(b) > 0 && b[len(b) - 1] == '/' {
		b = b[:len(b) - 1]
	}
	return fmt.aprintf("%s%s", b, path, allocator = allocator)
}

// ===========================================================================
// CLI: leaderboard <sub>
// ===========================================================================

cli_leaderboard :: proc(session: ^Session, args: []string) {
	sub := len(args) >= 1 ? args[0] : "status"
	switch sub {
	case "status", "":
		lb_cli_status(session)
	case "start":
		if session.lb_run.active {
			fmt.println("leaderboard: already recording. `leaderboard status` for progress.")
			return
		}
		if session.lb_net_busy {
			fmt.eprintln("leaderboard: a submission is still in flight - wait for it before starting a new run.")
			return
		}
		lb_start(session)
		fmt.printfln("leaderboard: recording started. Submit becomes available after %d min (`leaderboard submit <name>`).", LB_MIN_SEC / 60)
	case "stop":
		if !session.lb_run.active {
			fmt.println("leaderboard: not recording.")
			return
		}
		lb_stop(session)
		fmt.printfln("leaderboard: recording stopped at %s. %d kills, %d penya. Submit with `leaderboard submit <name>`.", fmt_elapsed(i64(lb_elapsed_sec(session)) * 1_000_000_000), session.lb_run.kills, lb_penya(session))
	case "submit":
		if len(args) < 2 {
			fmt.eprintln("usage: leaderboard submit <name>")
			return
		}
		// The REPL tokenizer splits on whitespace (no quote handling), so a multi-word name arrives as
		// several args - rejoin them and strip any surrounding quotes. Works for `submit Cool Farmer`,
		// `submit 'Cool Farmer'`, and the radar modal (which enqueues the raw typed name).
		name := strings.trim_space(strings.join(args[1:], " ", context.temp_allocator))
		name = strings.trim(name, "'\"")
		lb_cli_submit(session, name)
	case "top", "board", "refresh":
		sort := 0
		if len(args) >= 2 {
			if idx, found := lb_sort_index(args[1]); found {
				sort = idx
			} else {
				fmt.eprintfln("unknown sort '%s' (want: penya|kpm|kills|monsters|density)", args[1])
				return
			}
		}
		// `refresh` is the UI-driven fetch: it populates the board silently (no console table) so the radar
		// dialog can re-rank without spamming the REPL; `top`/`board` print the table for CLI use.
		lb_cli_fetch(session, sort, sub != "refresh")
	case "getcfg", "get":
		if len(args) < 2 {
			fmt.eprintln("usage: leaderboard getcfg <id> [path]")
			return
		}
		id, iok := strconv.parse_int(args[1])
		if !iok || id <= 0 {
			fmt.eprintfln("invalid id '%s'", args[1])
			return
		}
		path := len(args) >= 3 ? args[2] : fmt.tprintf("flyff_%d.cfg", id)
		lb_cli_getcfg(session, id, path)
	case "url":
		if len(args) < 2 {
			u, on := lb_url(session)
			fmt.printfln("leaderboard_url = %s", on ? u : "(unset)")
			return
		}
		cli_set(session, {"leaderboard_url", args[1]}) // reuse the config path (validates attach + saves)
	case:
		fmt.eprintln("usage: leaderboard [status|start|stop|submit <name>|top [sort]|getcfg <id> [path]|url [value]]")
	}
}

lb_sort_index :: proc(name: string) -> (int, bool) {
	for s, i in LB_SORTS {
		if s == name {
			return i, true
		}
	}
	return 0, false
}

lb_cli_status :: proc(session: ^Session) {
	u, on := lb_url(session)
	fmt.println("=== leaderboard ===")
	fmt.printfln("  backend : %s", on ? u : "(unset - `set leaderboard_url <url>`)")
	if session.lb_run.active || session.lb_run.start_ns != 0 {
		el := lb_elapsed_sec(session)
		ready := el >= LB_MIN_SEC
		fmt.printfln(
			"  run     : %s  %s  %d kills  %d penya  %.1f kpm  peak-density %d  %d species",
			session.lb_run.active ? "RECORDING" : "stopped",
			fmt_elapsed(i64(el) * 1_000_000_000),
			session.lb_run.kills, lb_penya(session), lb_kpm(session), session.lb_run.max_density, len(session.lb_run.names),
		)
		if session.lb_run.submitted {
			fmt.println("  submit  : DONE - already on the board (`leaderboard start` a new run to submit again).")
		} else if session.lb_run.active {
			fmt.printfln("  submit  : %s", ready ? "READY (`leaderboard submit <name>`)" : fmt.tprintf("locked - need %d min (%d:%02d elapsed)", LB_MIN_SEC / 60, el / 60, el % 60))
		} else {
			fmt.printfln("  submit  : %s", ready ? "READY (`leaderboard submit <name>`)" : "run too short (start a longer run)")
		}
	} else {
		fmt.println("  run     : idle - `leaderboard start` to begin a timed run.")
	}
	if st := lb_status_str(session); st != "" {
		fmt.printfln("  last    : %s", st)
	}
}

lb_cli_submit :: proc(session: ^Session, name: string) {
	if _, on := lb_url(session); !on {
		fmt.eprintln("leaderboard: no backend. `set leaderboard_url <url>` first.")
		return
	}
	if session.lb_run.start_ns == 0 {
		fmt.eprintln("leaderboard: no run to submit. `leaderboard start` first.")
		return
	}
	if session.lb_run.submitted {
		fmt.eprintln("leaderboard: this run is already on the board. `leaderboard start` a new run to submit again.")
		return
	}
	if session.lb_net_busy {
		fmt.eprintln("leaderboard: a request is already in flight - wait for it.")
		return
	}
	if name == "" {
		fmt.eprintln("leaderboard: a name is required (`leaderboard submit <name>`).")
		return
	}
	lb_stop(session) // finalize the span before snapshotting
	el := lb_elapsed_sec(session)
	if el < LB_MIN_SEC {
		fmt.eprintfln("leaderboard: run too short (%d:%02d) - need at least %d min.", el / 60, el % 60, LB_MIN_SEC / 60)
		return
	}
	body, ok := lb_build_payload(session, name)
	if !ok {
		fmt.eprintln("leaderboard: failed to build the submission payload.")
		return
	}
	u, _ := lb_url(session)
	job := new(Lb_Job)
	job.session = session
	job.kind = .Submit
	job.url = lb_join(u, "/api/v1/submit")
	job.body = body
	job.verbose = true
	session.lb_net_busy = true
	session.lb_run.submitted = true // optimistic: block re-submit now; the worker clears it if the request never reached the server
	lb_set_status(session, "submitting...")
	lb_spawn(job)
	fmt.printfln("leaderboard: submitting '%s' (%d kills, %d penya, %s)...", name, session.lb_run.kills, lb_penya(session), fmt_elapsed(i64(el) * 1_000_000_000))
}

lb_cli_fetch :: proc(session: ^Session, sort: int, verbose: bool) {
	u, on := lb_url(session)
	if !on {
		fmt.eprintln("leaderboard: no backend. `set leaderboard_url <url>` first.")
		return
	}
	if session.lb_net_busy {
		fmt.eprintln("leaderboard: a request is already in flight - wait for it.")
		return
	}
	job := new(Lb_Job)
	job.session = session
	job.kind = .Fetch
	job.url = lb_join(u, fmt.tprintf("/api/v1/leaderboard?sort=%s&limit=100", LB_SORTS[sort]))
	job.sort = sort
	job.verbose = verbose
	session.lb_net_busy = true
	lb_set_status(session, "loading...")
	lb_spawn(job)
	if verbose {
		fmt.printfln("leaderboard: fetching top by %s...", LB_SORTS[sort])
	}
}

lb_cli_getcfg :: proc(session: ^Session, id: int, path: string) {
	u, on := lb_url(session)
	if !on {
		fmt.eprintln("leaderboard: no backend. `set leaderboard_url <url>` first.")
		return
	}
	if session.lb_net_busy {
		fmt.eprintln("leaderboard: a request is already in flight - wait for it.")
		return
	}
	job := new(Lb_Job)
	job.session = session
	job.kind = .Getcfg
	job.url = lb_join(u, fmt.tprintf("/api/v1/entry/%d/config", id))
	job.path = strings.clone(path)
	job.id = id
	job.verbose = true
	session.lb_net_busy = true
	lb_set_status(session, "downloading...")
	lb_spawn(job)
	fmt.printfln("leaderboard: downloading config #%d -> %s ...", id, path)
}
