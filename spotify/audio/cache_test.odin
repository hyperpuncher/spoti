package audio

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
encrypted_ranges_survive_reopening_and_missing_ranges_stay_missing :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "spoti-audio-cache-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	id: [20]u8
	id[0] = 1
	cache := open_disk_cache(id, dir)
	first := make([]u8, RANGE_SIZE)
	defer delete(first)
	for &byte, i in first {byte = u8(i % 251)}
	total := RANGE_SIZE * 2 + 17
	write_disk_range(&cache, 0, total, first)
	last: [17]u8 = 42
	write_disk_range(&cache, RANGE_SIZE * 2, total, last[:])
	testing.expect(t, cache.file != nil)
	close_disk_cache(&cache)
	cache = open_disk_cache(id, dir)
	defer close_disk_cache(&cache)
	bytes, found := read_disk_range(&cache, 0)
	testing.expect(t, found && len(bytes) == len(first))
	if found {for byte, i in bytes {testing.expect_value(t, byte, first[i])}}
	delete(bytes)
	bytes, found = read_disk_range(&cache, RANGE_SIZE)
	testing.expect(t, !found && len(bytes) == 0)
	bytes, found = read_disk_range(&cache, RANGE_SIZE * 2)
	testing.expect(t, found && len(bytes) == 17)
	if found {for byte in bytes {testing.expect_value(t, byte, u8(42))}}
	delete(bytes)
}

@(test)
corrupt_ciphertext_is_rejected_and_can_be_replaced :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "spoti-audio-corrupt-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	id: [20]u8
	id[0] = 2
	cache := open_disk_cache(id, dir)
	defer close_disk_cache(&cache)
	ciphertext: [512]u8 = 7
	write_disk_range(&cache, 0, len(ciphertext), ciphertext[:])
	wrong: [1]u8 = 8
	_, _ = os.write_at(cache.file, wrong[:], i64(cache_payload_offset(cache.total)))
	bytes, found := read_disk_range(&cache, 0)
	testing.expect(t, !found && len(bytes) == 0)
	write_disk_range(&cache, 0, len(ciphertext), ciphertext[:])
	bytes, found = read_disk_range(&cache, 0)
	testing.expect(t, found && bytes[0] == 7)
	delete(bytes)
}

@(test)
cache_evicts_least_recently_used_closed_track :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "spoti-audio-lru-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	budget := i64(2 * (512 + cache_payload_offset(512)))
	paths: [2]string
	defer {delete(paths[0]); delete(paths[1])}
	bytes: [512]u8 = 4
	for index in 0 ..< 2 {
		id: [20]u8
		id[0] = u8(index + 10)
		cache := open_disk_cache(id, dir, budget)
		write_disk_range(&cache, 0, len(bytes), bytes[:])
		paths[index] = strings.clone(cache.path)
		close_disk_cache(&cache)
		stamp := time.time_add(time.now(), time.Duration(index - 2) * time.Hour)
		testing.expect(t, os.change_times(paths[index], stamp, stamp) == nil)
	}
	id: [20]u8
	id[0] = 12
	third := open_disk_cache(id, dir, budget)
	defer close_disk_cache(&third)
	write_disk_range(&third, 0, len(bytes), bytes[:])
	testing.expect(t, third.file != nil)
	old, old_err := os.open(paths[0])
	if old != nil {os.close(old)}
	testing.expect_value(t, old_err, os.Error(.Not_Exist))
	newer, newer_err := os.open(paths[1])
	if newer != nil {os.close(newer)}
	testing.expect(t, newer_err == nil)
}

@(test)
cache_budget_evicts_closed_tracks_but_protects_active_tracks :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "spoti-audio-eviction-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	budget := i64(512 + cache_payload_offset(512))
	id: [20]u8
	id[0] = 3
	first := open_disk_cache(id, dir, budget)
	bytes: [512]u8 = 4
	write_disk_range(&first, 0, len(bytes), bytes[:])
	old_path := strings.clone(first.path)
	defer delete(old_path)
	id[0] = 4
	second := open_disk_cache(id, dir, budget)
	defer close_disk_cache(&second)
	write_disk_range(&second, 0, len(bytes), bytes[:])
	testing.expect(t, second.file == nil, "active tracks must not be evicted")
	close_disk_cache(&first)
	write_disk_range(&second, 0, len(bytes), bytes[:])
	testing.expect(t, second.file != nil)
	old_file, old_err := os.open(old_path)
	if old_file != nil {os.close(old_file)}
	testing.expect_value(t, old_err, os.Error(.Not_Exist))
	entries, scan_err := os.read_directory_by_path(dir, -1, context.allocator)
	testing.expect(t, scan_err == nil)
	used: i64
	for entry in entries {used += entry.size; os.file_info_delete(entry, context.allocator)}
	delete(entries)
	testing.expect(t, used <= budget)
}
