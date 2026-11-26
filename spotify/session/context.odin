package session

import http "../http"
import "core:encoding/json"
import "core:fmt"
import "core:net"

Playback_Context :: struct {
	uri:   string,
	pages: []struct {
		tracks: []struct {
			uri, uid: string,
			gid:      string, // protobuf JSON encodes raw IDs as base64
		},
	},
}

// The returned strings and rows belong to the caller's temporary allocator.
fetch_context :: proc(
	access, uri: string,
	cancel: ^bool,
	reuse: rawptr,
) -> (
	ctx: Playback_Context,
	status: int,
	ok: bool,
) {
	encoded := net.percent_encode(uri, context.temp_allocator)
	address := fmt.tprintf("https://spclient.wg.spotify.com/context-resolve/v1/%s", encoded)
	body, code, fetched := http.get(
		address,
		{bearer = access, cancel = cancel, limit = 1024 * 1024},
		reuse,
	)
	defer delete(body)
	if !fetched || code != 200 {return {}, code, false}
	if json.unmarshal(body[:], &ctx, allocator = context.temp_allocator) !=
	   nil {return {}, -1, false}
	return ctx, code, true
}
