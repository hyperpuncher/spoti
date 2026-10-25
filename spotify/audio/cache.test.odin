package audio

import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
independent_cache_handles_read_and_write_concurrently :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-audio-parallel-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	Work :: struct {
		cache: Disk_Cache,
		byte:  u8,
		ok:    bool,
	}
	works: [2]Work
	workers: [2]^thread.Thread
	defer {
		for worker in workers {if worker != nil {thread.join(worker); thread.destroy(worker)}}
		for &work in works {close_disk_cache(&work.cache)}
	}
	for &work, index in works {
		id: [20]u8
		id[0] = u8(index + 20)
		work.cache = open_disk_cache(id, dir)
		work.byte = u8(index + 1)
		bytes: [RANGE_SIZE]u8
		for &byte in bytes {byte = work.byte}
		write_disk_range(&work.cache, 0, 2 * RANGE_SIZE, bytes[:])
		workers[index] = thread.create_and_start_with_data(&work, proc(pointer: rawptr) {
			work := (^Work)(pointer)
			bytes: [RANGE_SIZE]u8
			for &byte in bytes {byte = work.byte}
			write_disk_range(&work.cache, RANGE_SIZE, 2 * RANGE_SIZE, bytes[:])
			work.ok = true
			for start in ([]int{0, RANGE_SIZE}) {
				cached, found := read_disk_range(&work.cache, start)
				defer delete(cached)
				work.ok = work.ok && found && len(cached) == RANGE_SIZE
				for byte in cached {work.ok = work.ok && byte == work.byte}
			}
		})
		if !testing.expect(t, workers[index] != nil) {return}
	}
	for &worker, index in workers {
		thread.join(worker)
		thread.destroy(worker)
		worker = nil
		testing.expect(t, works[index].ok)
	}
}

@(test)
encrypted_ranges_survive_reopening_and_missing_ranges_stay_missing :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-audio-cache-*", context.allocator)
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
	dir, err := os.make_directory_temp("", "spoti-audio-corrupt-*", context.allocator)
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
cache_retains_closed_tracks_when_the_budget_has_room :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-audio-room-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	budget := i64(2 * (512 + cache_payload_offset(512)))
	id: [20]u8
	id[0] = 5
	first := open_disk_cache(id, dir, budget)
	bytes: [512]u8 = 7
	write_disk_range(&first, 0, len(bytes), bytes[:])
	close_disk_cache(&first)
	id[0] = 6
	second := open_disk_cache(id, dir, budget)
	defer close_disk_cache(&second)
	write_disk_range(&second, 0, len(bytes), bytes[:])
	testing.expect(t, second.file != nil)
	id[0] = 5
	first = open_disk_cache(id, dir, budget)
	defer close_disk_cache(&first)
	cached, found := read_disk_range(&first, 0)
	defer delete(cached)
	testing.expect(t, found && len(cached) == len(bytes))
	if found {for byte in cached {testing.expect_value(t, byte, u8(7))}}
}

@(test)
cache_evicts_least_recently_used_closed_track :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-audio-lru-*", context.allocator)
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
	dir, err := os.make_directory_temp("", "spoti-audio-eviction-*", context.allocator)
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

@(test)
disk_cache_complete_tracks_range_presence :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-audio-complete-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	id: [20]u8
	id[0] = 9
	testing.expect(t, !disk_cache_complete(id, dir), "absent file is incomplete")
	cache := open_disk_cache(id, dir)
	defer close_disk_cache(&cache)
	total := 2 * RANGE_SIZE
	bytes: [RANGE_SIZE]u8 = 7
	write_disk_range(&cache, 0, total, bytes[:])
	testing.expect(t, !disk_cache_complete(id, dir), "partial ranges are incomplete")
	write_disk_range(&cache, RANGE_SIZE, total, bytes[:])
	testing.expect(t, disk_cache_complete(id, dir), "all ranges present is complete")
}
