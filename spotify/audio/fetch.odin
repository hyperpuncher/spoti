package audio

import diagnostic "../../diagnostic"
import http "../http"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

// Start and seek read one 64 KiB block because latency matters there. This
// worker downloads the rest of the track into the disk cache in large
// requests, ahead of the play position, so a slow request cannot stall
// playback once the file is on disk.
//
// At 320 kbps a track is about 8-12 MB, so 1 MiB requests finish a track in
// about 10 requests. Each request costs one round trip (about 50-130 ms to
// the CDN) plus its transfer time; at 1 MiB the transfer time dominates on
// any connection fast enough to stream, and a cancelled request wastes at
// most 1 MiB.
FETCH_BYTES :: 16 * RANGE_SIZE

Fetch :: struct {
	url:     string, // owned; signed CDN URL, never logged
	file_id: [20]u8,
	total:   int, // encrypted file size
	start:   int, // first block to fetch, aligned to RANGE_SIZE
	cancel:  bool, // atomic
	thread:  ^thread.Thread,
	get:     type_of(http.get), // tests replace the network
	cache:   string, // tests use a private cache directory
}

// Fetch the file from start to the end, then from the beginning to start.
// Blocks already on disk are skipped.
start_fetch :: proc(
	fetch: ^Fetch,
	url: string,
	file_id: [20]u8,
	total, position: int,
	get: type_of(http.get) = nil,
	cache := "",
) -> bool {
	if total <= SPOTIFY_OGG_OFFSET || url == "" {return false}
	fetch^ = {
		url     = strings.clone(url),
		file_id = file_id,
		total   = total,
		start   = clamp(position, 0, total - 1) / RANGE_SIZE * RANGE_SIZE,
		get     = get,
		cache   = cache,
	}
	if fetch.get == nil {fetch.get = http.get}
	fetch.thread = thread.create_and_start_with_data(fetch, run_fetch)
	if fetch.thread == nil {delete(fetch.url); fetch^ = {}; return false}
	return true
}

// finish waits for the walk to complete instead of cancelling it.
stop_fetch :: proc(fetch: ^Fetch, finish := false) {
	if fetch.thread == nil {return}
	if !finish {sync.atomic_store(&fetch.cancel, true)}
	thread.destroy(fetch.thread)
	delete(fetch.url)
	fetch^ = {}
}

run_fetch :: proc(pointer: rawptr) {
	fetch := (^Fetch)(pointer)
	disk := open_disk_cache(fetch.file_id, fetch.cache)
	defer close_disk_cache(&disk)
	reuse := http.open_handle()
	defer http.close_handle(reuse)
	blocks := (fetch.total + RANGE_SIZE - 1) / RANGE_SIZE
	first := fetch.start / RANGE_SIZE
	fetched := 0
	for step := 0; step < blocks; {
		if sync.atomic_load(&fetch.cancel) {return}
		block := (first + step) % blocks
		// Skip what the decoder or an earlier run already stored.
		if disk_has_block(&disk, block) {step += 1; continue}
		// Extend the request over missing blocks up to FETCH_BYTES, without
		// wrapping past the end of the file.
		count := 1
		for count < FETCH_BYTES / RANGE_SIZE &&
		    step + count < blocks &&
		    block + count < blocks &&
		    !disk_has_block(&disk, block + count) {count += 1}
		start := block * RANGE_SIZE
		end := min(start + count * RANGE_SIZE, fetch.total) - 1
		range := fmt.tprintf("%d-%d", start, end)
		info: http.Range_Info
		bytes, status, ok := fetch.get(
			fetch.url,
			{range = range, limit = FETCH_BYTES, range_info = &info, cancel = &fetch.cancel},
			reuse,
		)
		defer delete(bytes)
		free_all(context.temp_allocator)
		if !ok ||
		   status != 206 ||
		   !info.valid ||
		   info.start != start ||
		   info.end != end ||
		   info.total != fetch.total ||
		   len(bytes) != end - start + 1 {
			// The decoder still fetches what it needs on demand.
			if !sync.atomic_load(
				&fetch.cancel,
			) {diagnostic.writef("audio fetch stopped status=%d", status)}
			return
		}
		for offset := 0; offset < len(bytes); offset += RANGE_SIZE {
			chunk := bytes[offset:min(offset + RANGE_SIZE, len(bytes))]
			write_disk_range(&disk, start + offset, fetch.total, chunk)
		}
		fetched += len(bytes)
		step += count
	}
	diagnostic.writef("audio fetch complete bytes=%d", fetched)
}
