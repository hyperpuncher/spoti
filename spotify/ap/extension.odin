// BatchedEntityRequest / BatchedExtensionResponse wire helpers for the private
// extended-metadata service (extended_metadata.proto, entity_extension_data.proto).
// Shared by the library reads and the playback metadata path.
//
//   BatchedExtensionResponse { repeated ExtensionArray extension = 2 }
//   ExtensionArray { ExtensionHeader header = 1; ExtensionKind kind = 2;
//                    repeated EntityExtensionData entity_data = 3 }
//   EntityExtensionData { ExtensionHeader header = 1; string entity_uri = 2;
//                         Any extension_data = 3 }
//   Any { string type_url = 1; bytes value = 2 }
package ap

TRACK_V4 :: 10
AUDIO_FILES :: 5
EXTENDED_METADATA_ADDRESS :: "https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata"

// Both extension arrays and entities place their status in header field 1.
extension_status :: proc(message: []u8) -> (code: u64, ok: bool) {
	header, _, valid := get_bytes(message, 1)
	if !valid {return}
	code, _, ok = get_number(header, 1)
	return
}

// The embedded payload of the first entity of the chosen extension kind.
// found=false means the entity was unavailable (404/451).
extension_message :: proc(
	body: []u8,
	kind: u64,
	unavailable: ^bool = nil,
) -> (
	message: []u8,
	found, valid: bool,
) {
	if unavailable != nil {unavailable^ = false}
	pos := 0
	for pos < len(body) {
		field, wire, array, _, array_valid := next_field(body, &pos)
		if !array_valid {return nil, false, false}
		if field != 2 {continue}
		if wire != 2 {return nil, false, false}
		array_kind, _, kind_valid := get_number(array, 2)
		if !kind_valid {return nil, false, false}
		if array_kind != kind {continue}
		provider, provider_valid := extension_status(array)
		if !provider_valid || provider != 0 && provider != 200 {return nil, false, false}
		cursor := 0
		for cursor < len(array) {
			entity_field, entity_wire, entity, _, entity_valid := next_field(array, &cursor)
			if !entity_valid {return nil, false, false}
			if entity_field != 3 {continue}
			if entity_wire != 2 {return nil, false, false}
			code, status_valid := extension_status(entity)
			if !status_valid {return nil, false, false}
			if code == 404 || code == 451 {
				if unavailable != nil {unavailable^ = true}
				return nil, false, true
			}
			if code != 0 && code != 200 {return nil, false, false}
			any, has_data, data_valid := get_bytes(entity, 3)
			if !data_valid {return nil, false, false}
			if !has_data {return nil, false, true}
			payload, has_payload, payload_valid := get_bytes(any, 2)
			if !payload_valid {return nil, false, false}
			if !has_payload {return nil, false, true}
			return payload, true, true
		}
	}
	return nil, false, true
}

// Append one EntityRequest for one URI and extension kind.
extension_request :: proc(request: ^[dynamic]u8, uri: string, kind: u64) {
	entity := make([dynamic]u8)
	defer delete(entity)
	put_bytes(&entity, 1, transmute([]u8)uri)
	put_bytes(&entity, 2, []u8{0x08, u8(kind)})
	put_bytes(request, 2, entity[:])
}
