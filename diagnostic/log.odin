// Minimal crash breadcrumbs. Callers must never include credentials, URLs,
// Spotify IDs, audio keys, or response bodies.
package diagnostic

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

state: struct {
	mutex:         sync.Mutex,
	file:          ^os.File,
	cover_hits:    int,
	cover_misses:  int,
	cover_decoded: int,
	cover_failed:  int,
}

init :: proc() {
	sync.mutex_guard(&state.mutex)
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
