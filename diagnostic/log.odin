// Minimal crash breadcrumbs plus structured dev logging. Callers must never
// include credentials, URLs, Spotify IDs, audio keys, or response bodies.
// HTTP lines carry a sanitized endpoint shape (host plus alphabetic path
// segments, IDs and query dropped except paging offsets), a status code,
// byte count and duration. Pass -v for per-request cover lines.
package diagnostic

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

verbose: bool

state: struct {
	mutex:         sync.Mutex,
	file:          ^os.File,
	cover_hits:    int,
	cover_misses:  int,
	cover_decoded: int,
	cover_failed:  int,
}

init :: proc(enabled_verbose: bool = false) {
	sync.mutex_guard(&state.mutex)
	sync.atomic_store(&verbose, enabled_verbose)
	if state.file != nil {return}
	base, err := os.user_log_dir(context.allocator)
	if err != nil {return}
	defer delete(base)
	dir := fmt.aprintf("%s/spoti", base)
	defer delete(dir)
	dir_error := os.make_directory_all(dir)
	if dir_error != nil && dir_error != .Exist {return}
	path := fmt.aprintf("%s/spoti.log", dir)
	defer delete(path)
	state.file, _ = os.open(path, {.Write, .Create, .Append})
}

write :: proc(message: string) {
	sync.mutex_guard(&state.mutex)
	if state.file == nil {return}
	fmt.fprintf(state.file, "%v  %s\n", time.now(), message)
	_ = os.flush(state.file)
}

cover_cache_result :: proc(hit: bool) {
	sync.mutex_guard(&state.mutex)
	if hit {state.cover_hits += 1} else {state.cover_misses += 1}
	total := state.cover_hits + state.cover_misses
	if state.file != nil && total % 16 == 0 {
		fmt.fprintf(
			state.file,
			"%v  cover cache: %d hits, %d misses\n",
			time.now(),
			state.cover_hits,
			state.cover_misses,
		)
		_ = os.flush(state.file)
	}
}

cover_decode_result :: proc(ok: bool) {
	sync.mutex_guard(&state.mutex)
	if ok {state.cover_decoded += 1} else {state.cover_failed += 1}
}

// Failed HTTPS requests always log; successes are verbose-only. Lines
// carry a sanitized endpoint shape, a status code, a byte count and a
// duration. Privacy: no tokens, URLs, IDs, bodies, or query besides
// numeric paging offsets.
http :: proc(address: string, status, bytes: int, ms: f64) {
	failed := status < 200 || status >= 300
	if !failed && !sync.atomic_load(&verbose) {return}
	endpoint, paging := sanitize_endpoint(address, context.temp_allocator)
	line := fmt.aprintf(
		"http %s%s status=%d bytes=%d ms=%.0f",
		endpoint,
		paging,
		status,
		bytes,
		ms,
		allocator = context.temp_allocator,
	)
	write(line)
}

// Formatted dev line without a scoping block per call site.
writef :: proc(format: string, args: ..any) {
	write(fmt.aprintf(format, ..args, allocator = context.temp_allocator))
}

result :: proc(kind: string, ok: bool, status, rows, total: int, more: bool) {
	if !sync.atomic_load(&verbose) {return}
	line := fmt.aprintf(
		"library result=%s ok=%v status=%d rows=%d total=%d more=%v",
		kind,
		ok,
		status,
		rows,
		total,
		more,
		allocator = context.temp_allocator,
	)
	write(line)
}

// Frame-stage averages and maxima over the last window, for scroll hitches.
frame :: proc(events, layout, render: f64, max_events, max_layout, max_render: f64) {
	line := fmt.aprintf(
		"frame ms avg/max events+poll=%.1f/%.1f layout=%.1f/%.1f render+present=%.1f/%.1f",
		events,
		max_events,
		layout,
		max_layout,
		render,
		max_render,
		allocator = context.temp_allocator,
	)
	write(line)
}

// Host plus alphabetic path segments; IDs, hashes and query dropped, except
// numeric paging offsets, which show how far pagination has reached.
sanitize_endpoint :: proc(
	address: string,
	allocator := context.allocator,
) -> (
	endpoint, paging: string,
) {
	rest := address
	if index := strings.index(rest, "://"); index >= 0 {rest = rest[index + 3:]}
	host, path := rest, ""
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		host = rest[:slash]
		path = rest[slash:]
	}
	if dot := strings.index_byte(host, '.'); dot >= 0 {host = host[:dot]}
	parts: [8]string
	count := 0
	if index := strings.index_byte(path, '?'); index >= 0 {
		paging = paging_offset(path[index:], allocator)
		path = path[:index]
	}
	for segment in strings.split(path, "/", context.temp_allocator) {
		if count >= len(parts) {break}
		if keep_segment(segment) {parts[count] = segment; count += 1}
	}
	joined := strings.join(parts[:count], "-", allocator)
	return fmt.aprintf("%s %s", host, joined, allocator = allocator), paging
}

keep_segment :: proc(segment: string) -> bool {
	if len(segment) == 0 || len(segment) > 16 {return false}
	for ch in transmute([]u8)segment {
		if ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '.' {continue}
		return false
	}
	return true
}

paging_offset :: proc(query: string, allocator := context.allocator) -> string {
	for key in ([]string{"offset", "from"}) {
		prefix := fmt.aprintf("%s=", key, allocator = context.temp_allocator)
		start := strings.index(query, prefix)
		if start < 0 {continue}
		digits := query[start + len(prefix):]
		end := 0
		for end < len(digits) && digits[end] >= '0' && digits[end] <= '9' {end += 1}
		if value, ok := strconv.parse_int(digits[:end]); ok {
			return fmt.aprintf(" offset=%d", value, allocator = allocator)
		}
	}
	return ""
}

close :: proc() {
	sync.mutex_guard(&state.mutex)
	if state.file == nil {return}
	fmt.fprintf(
		state.file,
		"%v  cover totals: %d cache hits, %d misses, %d decoded, %d failed\n",
		time.now(),
		state.cover_hits,
		state.cover_misses,
		state.cover_decoded,
		state.cover_failed,
	)
	_ = os.close(state.file)
	state.file = nil
}
