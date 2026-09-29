// Shared bounded Vorbis decode worker for the separate player and Clay app.
package player

import audio "../audio"
import "core:crypto"
import "core:sync"
import "core:sync/chan"

BUFFER_FRAMES :: 32768
PCM_BYTES :: BUFFER_FRAMES * 2 * size_of(i16)

Packet_Kind :: enum {
	Ready,
	Audio,
	End,
	Failed,
}
Packet :: struct {
	kind:        Packet_Kind,
	pcm:         []i16, // receiver owns Audio packets
	sample_rate: int,
	name:        string, // receiver owns Ready packet names
	duration_ms: int,
}

Work :: struct {
	url:    string, // borrowed until worker exits
	key:    [16]u8,
	queue:  chan.Chan(Packet),
	cancel: ^bool,
}

decode :: proc(pointer: rawptr) {
	work := (^Work)(pointer)
	defer crypto.zero_explicit(&work.key, size_of(work.key))
	media := audio.new_stream(work.url, work.key)
	defer audio.close_stream(&media)
	for {
		if work.cancel != nil && sync.atomic_load(work.cancel) {return}
		pcm := make([]i16, BUFFER_FRAMES * 2)
		frames, ok := audio.fill_pcm(&media, pcm)
		if work.cancel != nil && sync.atomic_load(work.cancel) {delete(pcm); return}
		if !ok || (frames > 0 && media.decoder.sample_rate <= 0) {
			delete(pcm)
			_ = chan.send(work.queue, Packet{kind = .Failed})
			return
		}
		if frames == 0 {
			delete(pcm)
			_ = chan.send(work.queue, Packet{kind = .End})
			return
		}
		if !chan.send(
			work.queue,
			Packet{kind = .Audio, pcm = pcm, sample_rate = media.decoder.sample_rate},
		) {
			delete(pcm)
			return
		}
	}
}
