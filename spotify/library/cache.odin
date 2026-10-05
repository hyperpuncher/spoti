// Small on-disk cache for Spotify Web API responses and cover images.
// Only 200 OK bodies reach the cache, so no token, error body or signed CDN
// URL is ever stored. API entries expire quickly; covers are immutable.
package library

import diagnostic "../../diagnostic"
import http "../http"
import "core:fmt"
import "core:os"
import "core:time"

API_TTL :: 5 * time.Minute
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

cache_read :: proc(
	prefix: string,
	address: string,
	ttl: time.Duration,
) -> (
	body: [dynamic]u8,
	ok: bool,
) {
	dir, has_dir := cache_directory(prefix)
	if !has_dir {return nil, false}
	defer delete(dir)
	path := fmt.aprintf("%s/%016x", dir, url_key(address))
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
	dir, has_dir := cache_directory(prefix)
	if !has_dir {return}
	defer delete(dir)
	path := fmt.aprintf("%s/%016x", dir, url_key(address))
	defer delete(path)
	_ = os.write_entire_file_from_bytes(path, body)
}

// Invalid decoded covers must not remain in the immutable-image cache.
cache_remove :: proc(prefix, address: string) {
	dir, ok := cache_directory(prefix)
	if !ok {return}
	defer delete(dir)
	path := fmt.aprintf("%s/%016x", dir, url_key(address))
	defer delete(path)
	_ = os.remove(path)
}

// One cached HTTPS GET. `prefix` keeps API entries and covers apart.
cached_get :: proc(
	prefix: string,
	address: string,
	options: http.Options = {},
	ttl: time.Duration = API_TTL,
	reuse: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	if cached, found := cache_read(prefix, address, ttl); found {
		if prefix == "cover" {diagnostic.cover_cache_result(true)}
		return cached, 200, true
	}
	if prefix == "cover" {diagnostic.cover_cache_result(false)}
	fresh, code, fetched := http.get(address, options, reuse)
	if !fetched {return nil, code, false}
	if code == 200 {cache_write(prefix, address, fresh[:])}
	return fresh, code, true
}

api_get :: proc(
	access, address: string,
	limit: int,
	reuse: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	return cached_get("api", address, {bearer = access, limit = limit}, API_TTL, reuse)
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
