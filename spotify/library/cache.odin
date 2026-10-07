// Small on-disk cache for Spotify Web API responses and cover images.
// Only 200 OK bodies reach the cache, so no token, error body or signed CDN
// URL is ever stored. Library pages stay fresh for hours and fall back to the
// last good body when the api refuses; covers are immutable.
package library

import diagnostic "../../diagnostic"
import http "../http"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:time"

API_TTL :: 5 * time.Minute
// Library index pages change slowly, so a body inside PAGE_TTL is served
// straight from disk and a relaunch costs no api requests at all.
PAGE_TTL :: 6 * time.Hour
// When the api refuses (quota, rate limit, offline) the last good body still
// beats an empty tab, so any cached api body younger than this is a fallback.
API_STALE :: 30 * 24 * time.Hour
COVER_TTL :: 30 * 24 * time.Hour

cache_directory :: proc(prefix: string) -> (dir: string, ok: bool) {
	base, err := os.user_cache_dir(context.allocator)
	if err != nil {return "", false}
	defer delete(base)
	dir = fmt.aprintf("%s/spoti/%s", base, prefix)
	directory_error := os.make_directory_all(dir)
	if directory_error != nil && directory_error != .Exist {
		delete(dir)
		return "", false
	}
	return dir, true
}

cache_path :: proc(prefix: string, address: string) -> (path: string, ok: bool) {
	dir, has_dir := cache_directory(prefix)
	if !has_dir {return "", false}
	defer delete(dir)
	return fmt.aprintf("%s/%016x", dir, url_key(address)), true
}

cache_read :: proc(
	prefix: string,
	address: string,
	ttl: time.Duration,
) -> (
	body: [dynamic]u8,
	ok: bool,
) {
	path, has_path := cache_path(prefix, address)
	if !has_path {return nil, false}
	defer delete(path)
	if ttl > 0 {
		written, time_error := os.modification_time_by_path(path)
		if time_error == nil && time.since(written) > ttl {return nil, false}
	}
	bytes, read_error := os.read_entire_file_from_path(path, context.allocator)
	if read_error != nil {return nil, false}
	body = make([dynamic]u8, len(bytes), len(bytes))
	copy(body[:], bytes)
	delete(bytes)
	return body, true
}

cache_write :: proc(prefix: string, address: string, body: []u8) {
	if len(body) == 0 {return}
	path, has_path := cache_path(prefix, address)
	if !has_path {return}
	defer delete(path)
	// Write beside the target and rename into place, so a crash can never
	// leave a half body that a later read would trust.
	temp := fmt.aprintf("%s.tmp", path)
	defer delete(temp)
	if os.write_entire_file_from_bytes(temp, body) != nil {return}
	_ = os.rename(temp, path)
}

// Mtime check without reading: lets paging skip its quota pacing for
// bodies already on disk instead of spacing out cache hits.
cache_fresh :: proc(prefix: string, address: string, ttl: time.Duration) -> bool {
	path, has_path := cache_path(prefix, address)
	if !has_path {return false}
	defer delete(path)
	written, time_error := os.modification_time_by_path(path)
	if time_error != nil {return false}
	if ttl <= 0 {return true}
	return time.since(written) <= ttl
}

// Invalid decoded covers must not remain in the immutable-image cache.
cache_remove :: proc(prefix, address: string) {
	path, ok := cache_path(prefix, address)
	if !ok {return}
	defer delete(path)
	_ = os.remove(path)
}

// Read-time TTLs only hide old bodies, so the api directory would otherwise
// grow forever. Swept once when the library worker starts.
cache_prune :: proc(prefix: string, max_age: time.Duration) {
	dir, has_dir := cache_directory(prefix)
	if !has_dir {return}
	defer delete(dir)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {return}
	defer virtual.arena_destroy(&arena)
	entries, read_error := os.read_directory_by_path(dir, -1, virtual.arena_allocator(&arena))
	if read_error != nil {return}
	removed := 0
	for entry in entries {
		if entry.type == .Directory || time.since(entry.modification_time) <= max_age {continue}
		path := fmt.aprintf("%s/%s", dir, entry.name, allocator = virtual.arena_allocator(&arena))
		if os.remove(path) == nil {removed += 1}
	}
	if removed > 0 {diagnostic.writef("library cache pruned prefix=%s files=%d", prefix, removed)}
}

// One cached HTTPS GET. `prefix` keeps API entries and covers apart.
cached_get :: proc(
	prefix: string,
	address: string,
	options: http.Options = {},
	ttl: time.Duration = API_TTL,
	reuse: rawptr = nil,
	stale: time.Duration = 0,
	cache_only: bool = false,
	refresh: bool = false,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	// A refresh skips the TTL read and goes to the network; the fresh body
	// still rewrites the cache, and stale still covers a failed fetch.
	if !refresh {
		if cached, hit := cache_read(prefix, address, ttl); hit {
			if prefix == "cover" {diagnostic.cover_cache_result(true)}
			return cached, 200, true
		}
	}
	if prefix == "cover" {diagnostic.cover_cache_result(false)}
	if cache_only {
		if older, found := cache_read(prefix, address, stale); found {return older, 200, true}
		return nil, 0, false
	}
	fresh, code, fetched := http.get(address, options, reuse)
	if fetched && code == 200 {
		cache_write(prefix, address, fresh[:])
		return fresh, code, true
	}
	delete(fresh)
	if stale > 0 {
		if older, found := cache_read(prefix, address, stale); found {
			diagnostic.writef("library api reused stale body status=%d", code)
			return older, 200, true
		}
	}
	return nil, code, fetched
}

api_get :: proc(
	access, address: string,
	limit: int,
	reuse: rawptr = nil,
	retry_after: ^int = nil,
	ttl: time.Duration = API_TTL,
	stale: time.Duration = API_STALE,
	cache_only: bool = false,
	refresh: bool = false,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	return cached_get(
		"api",
		address,
		{bearer = access, limit = limit, retry_after = retry_after},
		ttl,
		reuse,
		stale,
		cache_only,
		refresh,
	)
}

cover_get :: proc(
	address: string,
	reuse: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	return cached_get("cover", address, {limit = 4 * 1024 * 1024}, COVER_TTL, reuse)
}
