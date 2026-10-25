package main

import "core:os"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import audio "spotify/audio"
import player "spotify/player"

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
		ending, ended := chan.try_recv(queue)
		testing.expect(t, ended && ending.kind == .End)
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
