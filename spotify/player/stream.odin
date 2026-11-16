// Bounded, seekable Vorbis playback worker.
package player

import audio "../audio"
import "core:sync"
import "core:sync/chan"

BUFFER_FRAMES :: 32768
PCM_BYTES :: BUFFER_FRAMES * 2 * size_of(i16)

Packet_Kind :: enum {
	Ready,
	Audio,
	End,
	Failed,
	Unavailable,
}
Packet :: struct {
	kind:            Packet_Kind,
	pcm:             []i16, // receiver owns Audio packets
	sample_rate:     int,
	name:            string, // receiver owns Ready packet names
	uri:             string, // receiver owns; the track a Ready packet starts
	duration_ms:     int,
	position_frames: int, // absolute PCM position, including a seek offset
	frames:          int, // valid frames in the owned, fixed-size PCM allocation
}

Work :: struct {
	media:    ^audio.Seek_Stream, // owned by the playback source across seeks
	queue:    chan.Chan(Packet),
	cancel:   ^bool,
	start_ms: int,
	// Optional; called once the stream is open and positioned.
	on_open:  proc(media: ^audio.Seek_Stream, user: rawptr),
	user:     rawptr,
}

decode :: proc(pointer: rawptr) -> (ok: bool) {
	work := (^Work)(pointer)
	media := work.media
	media.failed = false
	if (media.handle == nil && !audio.open_seek_stream(media)) ||
	   !audio.seek_to_ms(media, work.start_ms) {
		if work.cancel == nil ||
		   !sync.atomic_load(work.cancel) {_ = chan.send(work.queue, Packet{kind = .Failed})}
		return
	}
	if work.on_open != nil {work.on_open(media, work.user)}
	for {
		if work.cancel != nil && sync.atomic_load(work.cancel) {return}
		pcm := make([]i16, BUFFER_FRAMES * 2)
		// Each iteration owns its buffer until a successful channel transfer.
		defer delete(pcm)
		position := audio.seek_frame_position(media)
		frames, read_ok := audio.read_seek_pcm(media, pcm)
		if work.cancel != nil && sync.atomic_load(work.cancel) {return}
		if !read_ok || (frames > 0 && media.sample_rate <= 0) {
			_ = chan.send(work.queue, Packet{kind = .Failed})
			return
		}
		// The caller reports the end, or continues with the next track.
		if frames == 0 {return true}
		if !chan.send(
			work.queue,
			Packet {
				kind = .Audio,
				pcm = pcm,
				frames = frames,
				sample_rate = media.sample_rate,
				position_frames = position,
			},
		) {return}
		pcm = nil // The receiver now owns the complete allocation.
	}
}
