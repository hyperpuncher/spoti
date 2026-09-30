package audio

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

DEFAULT_AUDIO_CACHE_BYTES :: i64(4 * 1024 * 1024 * 1024)
MAX_CACHE_TRACK_BYTES :: 512 * 1024 * 1024
CACHE_MAGIC :: "SPOTICA1"
CACHE_HEADER_BYTES :: 16
CACHE_BLOCK_META_BYTES :: 5 // presence byte plus ciphertext CRC32

// One sparse file contains range metadata and the original encrypted bytes.
// No audio key, token, signed URL, track title, or decoded PCM reaches disk.
Disk_Cache :: struct {
	file:            ^os.File,
	path, directory: string,
	total:           int,
	blocks:          []u8,
	limit:           i64,
}
cache_mutex: sync.Mutex
cache_active: map[string]int

cache_protect :: proc(path: string) {
	// This shared map outlives individual worker/test allocator scopes.
	context = runtime.default_context()
	if cache_active == nil {cache_active = make(map[string]int)}
	if count, found := cache_active[path]; found {cache_active[path] = count + 1} else {
		cache_active[strings.clone(path)] = 1
	}
}

cache_unprotect :: proc(path: string) {
	context = runtime.default_context()
	for key, count in cache_active {
		if key != path {continue}
		if count > 1 {cache_active[key] = count - 1} else {
			delete_key(&cache_active, key)
			delete(key)
		}
		break
	}
	if len(cache_active) == 0 {delete(cache_active); cache_active = nil}
}

cache_payload_offset :: proc(total: int) -> int {
	return CACHE_HEADER_BYTES + ((total + RANGE_SIZE - 1) / RANGE_SIZE) * CACHE_BLOCK_META_BYTES
}

open_disk_cache :: proc(
	id: [20]u8,
	directory: string = "",
	limit: i64 = DEFAULT_AUDIO_CACHE_BYTES,
) -> Disk_Cache {
	cache := Disk_Cache {
		limit = limit,
	}
	if id == ([20]u8{}) || limit <= 0 {return cache}
	if directory == "" {
		base, err := os.user_cache_dir(context.allocator)
		if err != nil {return cache}
		defer delete(base)
		cache.directory = fmt.aprintf("%s/spoti/audio", base)
	} else {cache.directory = strings.clone(directory)}
	file_id := id
	name := hex.encode(file_id[:])
	defer delete(name)
	cache.path = fmt.aprintf("%s/%s.audio", cache.directory, string(name))
	sync.mutex_lock(&cache_mutex)
	defer sync.mutex_unlock(&cache_mutex)
	cache_protect(cache.path)
	file, err := os.open(cache.path, {.Read, .Write}, os.perm(0o600))
	if err != nil {return cache}
	valid := false
	defer if !valid {os.close(file); _ = os.remove(cache.path)}
	header: [CACHE_HEADER_BYTES]u8
	n, read_err := os.read_at(file, header[:], 0)
	if read_err != nil || n != len(header) || string(header[:8]) != CACHE_MAGIC {return cache}
	total := endian.unchecked_get_u64le(header[8:])
	if total <= SPOTIFY_OGG_OFFSET || total > MAX_CACHE_TRACK_BYTES {return cache}
	payload := cache_payload_offset(int(total))
	size, size_err := os.file_size(file)
	if size_err != nil || size != i64(payload) + i64(total) || size > limit {return cache}
	blocks := make([]u8, payload - CACHE_HEADER_BYTES)
	n, read_err = os.read_at(file, blocks, CACHE_HEADER_BYTES)
	if read_err != nil || n != len(blocks) {delete(blocks); return cache}
	cache.file, cache.total, cache.blocks = file, int(total), blocks
	// mtime is our last-used marker, independent of mount atime policy.
	_, _ = os.write_at(file, header[:1], 0)
	valid = true
	return cache
}

close_disk_cache :: proc(cache: ^Disk_Cache) {
	sync.mutex_lock(&cache_mutex)
	defer sync.mutex_unlock(&cache_mutex)
	if cache.file != nil {os.close(cache.file)}
	if cache.path != "" {cache_unprotect(cache.path)}
	delete(cache.blocks)
	delete(cache.path)
	delete(cache.directory)
	cache^ = {}
}

// Reserve logical file sizes, including partially filled files. Protected
// readers/writers are never evicted; if they fill the budget, skip caching.
cache_make_room :: proc(directory: string, limit, reserve: i64) -> bool {
	entries, err := os.read_directory_by_path(directory, -1, context.allocator)
	if err != nil {return false}
	defer {
		for entry in entries {os.file_info_delete(entry, context.allocator)}
		delete(entries)
	}
	total: i64
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".audio") {total += entry.size}
	}
	if total + reserve <= limit {return true}
	// Only order entries when eviction is actually needed.
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return time.diff(a.modification_time, b.modification_time) > 0
	})
	for entry in entries {
		if total + reserve <= limit {return true}
		if entry.type != .Regular ||
		   !strings.has_suffix(entry.name, ".audio") ||
		   entry.fullpath in cache_active {continue}
		if os.remove(entry.fullpath) == nil {total -= entry.size}
	}
	return total + reserve <= limit
}

read_disk_range :: proc(cache: ^Disk_Cache, start: int) -> (bytes: [dynamic]u8, found: bool) {
	if cache.file == nil || start < 0 || start >= cache.total || start % RANGE_SIZE != 0 {return}
	sync.mutex_lock(&cache_mutex)
	defer sync.mutex_unlock(&cache_mutex)
	index := start / RANGE_SIZE * CACHE_BLOCK_META_BYTES
	if cache.blocks[index] != 1 {return}
	bytes = make([dynamic]u8, min(RANGE_SIZE, cache.total - start))
	n, err := os.read_at(cache.file, bytes[:], i64(cache_payload_offset(cache.total) + start))
	crc := endian.unchecked_get_u32le(cache.blocks[index + 1:])
	if err != nil || n != len(bytes) || hash.crc32(bytes[:]) != crc {
		delete(bytes)
		bytes = nil
		cache.blocks[index] = 0
		_, _ = os.write_at(
			cache.file,
			cache.blocks[index:index + 1],
			i64(CACHE_HEADER_BYTES + index),
		)
		return
	}
	return bytes, true
}

write_disk_range :: proc(cache: ^Disk_Cache, start, total: int, bytes: []u8) {
	if cache.path == "" ||
	   total <= SPOTIFY_OGG_OFFSET ||
	   total > MAX_CACHE_TRACK_BYTES ||
	   start < 0 ||
	   start >= total ||
	   start % RANGE_SIZE != 0 ||
	   len(bytes) != min(RANGE_SIZE, total - start) {return}
	sync.mutex_lock(&cache_mutex)
	defer sync.mutex_unlock(&cache_mutex)
	if cache.file == nil {
		payload := cache_payload_offset(total)
		if i64(payload + total) > cache.limit {return}
		err := os.make_directory_all(cache.directory)
		if err != nil && err != .Exist {return}
		if !cache_make_room(cache.directory, cache.limit, i64(payload + total)) {return}
		file, open_err := os.open(cache.path, {.Read, .Write, .Create, .Excl}, os.perm(0o600))
		if open_err != nil {return}
		header: [CACHE_HEADER_BYTES]u8
		copy(header[:8], CACHE_MAGIC)
		endian.unchecked_put_u64le(header[8:], u64(total))
		n, write_err := os.write_at(file, header[:], 0)
		if write_err != nil || n != len(header) || os.truncate(file, i64(payload + total)) != nil {
			os.close(file)
			_ = os.remove(cache.path)
			return
		}
		cache.file, cache.total = file, total
		cache.blocks = make([]u8, payload - CACHE_HEADER_BYTES)
	}
	if cache.total != total {return}
	index := start / RANGE_SIZE * CACHE_BLOCK_META_BYTES
	if cache.blocks[index] == 1 {return}
	n, err := os.write_at(cache.file, bytes, i64(cache_payload_offset(total) + start))
	if err != nil || n != len(bytes) {return}
	meta: [CACHE_BLOCK_META_BYTES]u8
	meta[0] = 1
	endian.unchecked_put_u32le(meta[1:], hash.crc32(bytes))
	n, err = os.write_at(cache.file, meta[:], i64(CACHE_HEADER_BYTES + index))
	if err == nil && n == len(meta) {copy(cache.blocks[index:index + len(meta)], meta[:])}
}
