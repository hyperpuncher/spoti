package ap

// One-request Mercury GET over the encrypted AP connection. Command 0xb2.
// The response parser handles one FINAL packet; multipart responses must not
// be mistaken for complete metadata.
mercury_get :: proc(uri: string, sequence: u64) -> [dynamic]u8 {
	if len(uri) == 0 || len(uri) > 60000 {return nil}
	header := make([dynamic]u8)
	defer delete(header)
	put_bytes(&header, 1, transmute([]u8)uri)
	method: string = "GET"
	put_bytes(&header, 3, transmute([]u8)method)
	if len(header) > 65535 {return nil}
	packet := make([dynamic]u8, 0, 15 + len(header))
	append(&packet, 0, 8) // eight-byte sequence length
	for shift := 7; shift >= 0; shift -= 1 {
		append(&packet, u8(sequence >> u64(8 * shift)))
	}
	append(&packet, 1, 0, 1) // FINAL flag, one part
	append(&packet, u8(len(header) >> 8), u8(len(header)))
	append(&packet, ..header[:])
	return packet
}

// Views into a MAC-verified payload; only treat body as track data after all
// lengths, sequence, flags, and HTTP-style status are validated.
mercury_body :: proc(packet: []u8, expected_sequence: u64) -> (body: []u8, status: int, ok: bool) {
	if len(packet) < 15 || packet[0] != 0 || packet[1] != 8 {return nil, 0, false}
	sequence: u64
	for b in packet[2:10] {sequence = sequence << 8 | u64(b)}
	if sequence != expected_sequence || packet[10] != 1 {return nil, 0, false}
	parts := int(packet[11]) << 8 | int(packet[12])
	if parts < 1 || parts > 2 {return nil, 0, false}
	position := 13
	read_part :: proc(data: []u8, pos: ^int) -> (part: []u8, valid: bool) {
		if len(data) - pos^ < 2 {return nil, false}
		size := int(data[pos^]) << 8 | int(data[pos^ + 1])
		pos^ += 2
		if len(data) - pos^ < size {return nil, false}
		part = data[pos^:pos^ + size]
		pos^ += size
		return part, true
	}
	header, valid := read_part(packet, &position)
	if !valid {return nil, 0, false}
	code: u64
	present: bool
	code, present, valid = get_number(header, 4) // sint32 status_code
	if !valid || !present || code & 1 != 0 || code >> 1 > u64(max(i32)) {return nil, 0, false}
	status = int(code >> 1)
	if parts == 2 {body, valid = read_part(packet, &position)}
	if !valid || position != len(packet) {return nil, 0, false}
	return body, status, true
}
