package ap

// Audio-key request is file ID (20 bytes), track GID (16 bytes), a big-endian
// sequence (4 bytes), then two zero bytes. AP commands: 0x0c request,
// 0x0d key, 0x0e refusal. Keys must never be printed or stored on disk.
request_audio_key :: proc(file_id: [20]u8, track_id: [16]u8, sequence: u32) -> [42]u8 {
	packet: [42]u8
	for i in 0 ..< 20 {packet[i] = file_id[i]}
	for i in 0 ..< 16 {packet[i + 20] = track_id[i]}
	packet[36] = u8(sequence >> 24)
	packet[37] = u8(sequence >> 16)
	packet[38] = u8(sequence >> 8)
	packet[39] = u8(sequence)
	return packet
}

Audio_Key_Result :: enum {
	Invalid,
	Granted,
	Refused,
}

read_audio_key :: proc(
	command: u8,
	packet: []u8,
	expected_sequence: u32,
) -> (
	key: [16]u8,
	result: Audio_Key_Result,
) {
	if len(packet) < 4 {return {}, .Invalid}
	sequence := u32(packet[0]) << 24 | u32(packet[1]) << 16 | u32(packet[2]) << 8 | u32(packet[3])
	if sequence != expected_sequence {return {}, .Invalid}
	switch command {
	case 0x0d:
		if len(packet) != 20 {return {}, .Invalid}
		copy(key[:], packet[4:20])
		return key, .Granted
	case 0x0e:
		if len(packet) < 5 {return {}, .Invalid}
		return {}, .Refused
	}
	return {}, .Invalid
}
