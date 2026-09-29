package audio

import ap "../ap"
import "core:strings"

trusted_cdn :: proc(address: string) -> bool {
	if !strings.has_prefix(address, "https://") || len(address) > 4096 {return false}
	rest := address[len("https://"):]
	end := strings.index_byte(rest, '/')
	if end <= 0 {return false}
	host := rest[:end]
	return(
		strings.has_suffix(host, ".spotifycdn.com") ||
		strings.has_suffix(host, ".scdn.co") ||
		strings.has_suffix(host, ".akamaized.net") \
	)
}

// storage-resolve.proto from Spotify's spclient. The response can hold several
// short-lived signed CDN URLs. Return one view into the authenticated response;
// callers must keep the protobuf bytes alive and never log this URL.
cdn_url :: proc(response: []u8, expected_file: [20]u8) -> (address: string, ok: bool) {
	position := 0
	seen_result := false
	found_url := false
	seen_file := false
	for position < len(response) {
		field, wire, bytes, number, valid := ap.next_field(response, &position)
		if !valid {return "", false}
		switch field {
		case 1:
			if seen_result || wire != 0 || number != 0 {return "", false} 	// CDN, not storage/restricted
			seen_result = true
		case 2:
			if wire != 2 {return "", false}
			candidate := string(bytes)
			if !found_url && trusted_cdn(candidate) {
				address, found_url = candidate, true
			}
		case 4:
			if seen_file || wire != 2 || len(bytes) != 20 {return "", false}
			seen_file = true
			for i in 0 ..< 20 {if bytes[i] != expected_file[i] {return "", false}}
		}
	}
	return address, found_url
}
