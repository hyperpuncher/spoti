package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import audio "spotify/audio"
import player "spotify/player"
import session "spotify/session"

@(test)
playback_decoder_reuses_cached_media_and_transfers_partial_pcm :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("/tmp", "spoti-decode-*", context.allocator)
	if !testing.expect(t, dir_err == nil) {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	ogg, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(ogg)
	ciphertext := make([]u8, audio.SPOTIFY_OGG_OFFSET + len(ogg))
	defer delete(ciphertext)
	copy(ciphertext[audio.SPOTIFY_OGG_OFFSET:], ogg)
	key: [16]u8
	key[0] = 17
	cipher := audio.init(key)
	audio.process(&cipher, ciphertext)
	audio.reset(&cipher)
	id: [20]u8
	id[0] = 19
	disk := audio.open_disk_cache(id, dir)
	audio.write_disk_range(&disk, 0, len(ciphertext), ciphertext)
	audio.close_disk_cache(&disk)
	media := audio.Seek_Stream {
		key  = key,
		disk = audio.open_disk_cache(id, dir),
	}
	defer audio.close_seek_stream(&media)
	queue, allocation := chan.create_buffered(chan.Chan(player.Packet), 3, context.allocator)
	if !testing.expect(t, allocation == nil) {return}
	defer {
		for packet in chan.try_recv(queue) {delete(packet.pcm); delete(packet.name)}
		chan.destroy(queue)
	}
	cancel := false
	work := player.Work {
		media  = &media,
		queue  = queue,
		cancel = &cancel,
	}
	if !testing.expect(t, audio.open_seek_stream(&media)) {return}
	for start in ([]int{0, 150, 0}) {
		work.start_ms = start
		if !testing.expect(t, player.decode(&work)) {return}
		packet, received := chan.try_recv(queue)
		if !testing.expect(t, received) {return}
		defer delete(packet.pcm)
		testing.expect_value(t, packet.kind, player.Packet_Kind.Audio)
		testing.expect_value(t, packet.sample_rate, 44100)
		testing.expect_value(t, packet.position_frames, start * 44100 / 1000)
		testing.expect_value(t, packet.frames, 13230 - packet.position_frames)
		testing.expect_value(t, len(packet.pcm), player.BUFFER_FRAMES * 2)
		// The track's end is left to the caller, which may continue gaplessly.
		_, more := chan.try_recv(queue)
		testing.expect(t, !more)
	}
	// An invalid seek sends a failure, not audio.
	work.start_ms = -1
	testing.expect(t, !player.decode(&work))
	failure, failed := chan.try_recv(queue)
	testing.expect(t, failed && failure.kind == .Failed)
	work.start_ms = 0
	// Cancellation sends nothing, and a closed receiver releases rejected PCM.
	sync.atomic_store(&cancel, true)
	testing.expect(t, !player.decode(&work))
	_, received := chan.try_recv(queue)
	testing.expect(t, !received)
	sync.atomic_store(&cancel, false)
	chan.close(queue)
	testing.expect(t, !player.decode(&work))
}

@(private = "file")
gapless_fixture: struct {
	key: [16]u8,
}

@(private = "file")
gapless_open :: proc(
	_: session.Keyring_Mode = .None,
	_: ^bool = nil,
	track_url: string = "",
	_: ^bool = nil,
) -> (
	source: session.Source,
	ok: bool,
) {
	source.key = gapless_fixture.key
	source.file_id[0] = track_url == "spotify:track:b" ? 32 : 31
	source.name = strings.clone(track_url)
	source.storage = make([dynamic]u8, 1)
	source.url = "https://cdn.test/unused"
	return source, true
}

// One worker decodes the offered next track into the same packet stream:
// track A's samples, then a Ready for B, then B's samples from frame 0, then
// a single End. Nothing is dropped between them.
@(test)
worker_continues_into_the_offered_track_without_a_gap :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("/tmp", "spoti-gapless-*", context.allocator)
	if !testing.expect(t, dir_err == nil) {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	ogg, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(ogg)
	gapless_fixture.key[0] = 23
	for file in ([]u8{31, 32}) {
		ciphertext := make([]u8, audio.SPOTIFY_OGG_OFFSET + len(ogg))
		defer delete(ciphertext)
		copy(ciphertext[audio.SPOTIFY_OGG_OFFSET:], ogg)
		cipher := audio.init(gapless_fixture.key)
		audio.process(&cipher, ciphertext)
		audio.reset(&cipher)
		id: [20]u8
		id[0] = file
		disk := audio.open_disk_cache(id, dir)
		audio.write_disk_range(&disk, 0, len(ciphertext), ciphertext)
		audio.close_disk_cache(&disk)
	}
	queue, allocation := chan.create_buffered(chan.Chan(player.Packet), 16, context.allocator)
	if !testing.expect(t, allocation == nil) {return}
	defer {
		for packet in chan.try_recv(queue) {delete(packet.pcm); delete(packet.name); delete(packet.uri)}
		chan.destroy(queue)
	}
	cancel := false
	source: Play_Source
	defer clear_play_source(&source)
	next: Next_Track
	defer clear_next_track(&next)
	// Offered after the first track starts, as the main loop does.
	offer_next_track(&next, "spotify:track:b", 1, nil)
	work := Login_Work {
		queue     = queue,
		cancel    = &cancel,
		track_url = strings.clone("spotify:track:a"),
		source    = &source,
		next      = &next,
		open      = gapless_open,
		cache     = dir,
	}
	login_and_decode(&work)
	kinds: [dynamic]player.Packet_Kind
	defer delete(kinds)
	frames := [2]int{}
	track := -1
	for packet in chan.try_recv(queue) {
		defer {delete(packet.pcm); delete(packet.name); delete(packet.uri)}
		append(&kinds, packet.kind)
		if packet.kind == .Ready {track += 1}
		if packet.kind == .Audio && track >= 0 {
			testing.expect_value(t, packet.position_frames, frames[track])
			frames[track] += packet.frames
		}
	}
	want := []player.Packet_Kind{.Ready, .Audio, .Ready, .Audio, .End}
	testing.expect_value(t, len(kinds), len(want))
	for kind, index in kinds {if index < len(want) {testing.expect_value(t, kind, want[index])}}
	testing.expect_value(t, frames, [2]int{13230, 13230})
}
