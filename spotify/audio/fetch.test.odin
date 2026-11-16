package audio

import http "../http"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"

// A fake CDN that serves byte ranges of a deterministic file and records them.
@(private = "file")
fake_cdn: struct {
	mutex:    sync.Mutex,
	total:    int,
	requests: [dynamic]string,
}

@(private = "file")
fake_get :: proc(
	_: string,
	options: http.Options = {},
	_: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	sync.mutex_guard(&fake_cdn.mutex)
	append(&fake_cdn.requests, strings.clone(options.range))
	first, _, last := strings.partition(options.range, "-")
	start, _ := strconv.parse_int(first)
	end, _ := strconv.parse_int(last)
	body = make([dynamic]u8, end - start + 1)
	for &byte, index in body {byte = u8((start + index) % 251)}
	options.range_info^ = {start, end, fake_cdn.total, true}
	return body, 206, true
}

// The fetcher starts at the play position, wraps to the beginning, skips
// blocks the decoder already stored, and never asks for more than 1 MiB.
@(test)
fetch_downloads_from_the_play_position_and_wraps :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-fetch-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	defer {
		for request in fake_cdn.requests {delete(request)}
		delete(fake_cdn.requests)
		fake_cdn = {}
	}
	fake_cdn.total = 40 * RANGE_SIZE + 123
	id: [20]u8
	id[0] = 3
	// The decoder already holds block 2.
	decoder := open_disk_cache(id, dir)
	defer close_disk_cache(&decoder)
	block := make([]u8, RANGE_SIZE)
	defer delete(block)
	for &byte, index in block {byte = u8((2 * RANGE_SIZE + index) % 251)}
	write_disk_range(&decoder, 2 * RANGE_SIZE, fake_cdn.total, block)

	fetch: Fetch
	if !testing.expect(
		t,
		start_fetch(
			&fetch,
			"https://cdn.test/a",
			id,
			fake_cdn.total,
			30 * RANGE_SIZE + 5,
			fake_get,
			dir,
		),
	) {return}
	stop_fetch(&fetch, finish = true)

	want := []string {
		fmt.tprintf("%d-%d", 30 * RANGE_SIZE, fake_cdn.total - 1),
		fmt.tprintf("%d-%d", 0, 2 * RANGE_SIZE - 1),
		fmt.tprintf("%d-%d", 3 * RANGE_SIZE, 19 * RANGE_SIZE - 1),
		fmt.tprintf("%d-%d", 19 * RANGE_SIZE, 30 * RANGE_SIZE - 1),
	}
	testing.expect_value(t, len(fake_cdn.requests), len(want))
	for request, index in fake_cdn.requests {
		if index < len(want) {testing.expect_value(t, request, want[index])}
	}
	for start := 0; start < fake_cdn.total; start += RANGE_SIZE {
		bytes, found := read_disk_range(&decoder, start)
		defer delete(bytes)
		if !testing.expectf(t, found, "block at %d missing", start) {continue}
		testing.expect_value(t, bytes[0], u8(start % 251))
	}
}

// A second fake CDN, so the parallel tests never share request logs.
@(private = "file")
wait_cdn: struct {
	mutex:    sync.Mutex,
	total:    int,
	requests: [dynamic]string,
}

@(private = "file")
wait_get :: proc(
	_: string,
	options: http.Options = {},
	_: rawptr = nil,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	sync.mutex_guard(&wait_cdn.mutex)
	append(&wait_cdn.requests, strings.clone(options.range))
	first, _, last := strings.partition(options.range, "-")
	start, _ := strconv.parse_int(first)
	end, _ := strconv.parse_int(last)
	body = make([dynamic]u8, end - start + 1)
	for &byte, index in body {byte = u8((start + index) % 251)}
	options.range_info^ = {start, end, wait_cdn.total, true}
	return body, 206, true
}

// A decoder that needs a block the fetcher is downloading waits for it and
// reads it from disk instead of requesting it again.
@(test)
decoder_waits_for_a_block_in_flight :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "spoti-fetch-wait-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	defer {
		for request in wait_cdn.requests {delete(request)}
		delete(wait_cdn.requests)
		wait_cdn = {}
	}
	wait_cdn.total = 4 * RANGE_SIZE
	id: [20]u8
	id[0] = 5
	fetch: Fetch
	// The fetcher announces blocks 0..4 and then pauses before storing them.
	sync.mutex_lock(&wait_cdn.mutex)
	if !testing.expect(
		t,
		start_fetch(&fetch, "https://cdn.test/a", id, wait_cdn.total, 0, wait_get, dir),
	) {sync.mutex_unlock(&wait_cdn.mutex); return}
	for {
		sync.mutex_guard(&fetch.flight_lock)
		if fetch.flight[1] > 0 {break}
	}
	stream := Seek_Stream {
		url   = "https://cdn.test/a",
		size  = wait_cdn.total,
		disk  = open_disk_cache(id, dir),
		fetch = &fetch,
	}
	defer close_seek_stream(&stream)
	sync.mutex_unlock(&wait_cdn.mutex)
	testing.expect(t, load_seek_range(&stream, RANGE_SIZE))
	stop_fetch(&fetch, finish = true)
	testing.expect_value(t, len(wait_cdn.requests), 1)
}
