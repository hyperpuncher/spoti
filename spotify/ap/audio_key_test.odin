package ap

import "core:slice"
import "core:testing"

@(test)
audio_key_request_and_replies :: proc(t: ^testing.T) {
	file_id: [20]u8
	for i in 0 ..< 20 {file_id[i] = u8(i)}
	track_id: [16]u8
	for i in 0 ..< 16 {track_id[i] = u8(i + 20)}
	request := request_audio_key(file_id, track_id, 0x12345678)
	testing.expect(t, slice.equal(request[:20], file_id[:]))
	testing.expect(t, slice.equal(request[20:36], track_id[:]))
	testing.expect(t, slice.equal(request[36:], []u8{0x12, 0x34, 0x56, 0x78, 0, 0}))
	reply: [20]u8
	copy(reply[:4], request[36:40])
	for i in 4 ..< 20 {reply[i] = u8(i)}
	key, outcome := read_audio_key(0x0d, reply[:], 0x12345678)
	testing.expect(t, outcome == .Granted && slice.equal(key[:], reply[4:]))
	_, outcome = read_audio_key(0x0d, reply[:19], 0x12345678)
	testing.expect(t, outcome == .Invalid)
	_, outcome = read_audio_key(0x0d, reply[:], 1)
	testing.expect(t, outcome == .Invalid)
	_, outcome = read_audio_key(0x0e, []u8{0x12, 0x34, 0x56, 0x78, 0x01}, 0x12345678)
	testing.expect(t, outcome == .Refused)
}
