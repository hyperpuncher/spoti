package connect

import http "../http"
import "core:encoding/json"
import "core:fmt"
import "core:net"

// Fill a transfer from its playback context after any explicit queued items.
// This request runs on the Connect worker, never on the UI thread.
resolve_context :: proc(client: ^Client, access: string, event: ^Event, reuse: rawptr) -> bool {
	if event.context_uri == "" || event.context_uri == "-" {return len(event.tracks) > 0}
	encoded := net.percent_encode(event.context_uri, context.temp_allocator)
	address := fmt.aprintf(
		"https://spclient.wg.spotify.com/context-resolve/v1/%s",
		encoded,
		allocator = context.temp_allocator,
	)
	body, code, fetched := http.get(
		address,
		{bearer = access, cancel = &client.cancel, limit = 1024 * 1024},
		reuse,
	)
	defer delete(body)
	// A transfer can still play its supplied track if context resolution
	// fails. A play request without any tracks must fail.
	if !fetched || code != 200 {return len(event.tracks) > 0}
	wire: Request
	if json.unmarshal(body[:], &wire.command.ctx, allocator = context.temp_allocator) !=
	   nil {return len(event.tracks) > 0}
	started := false
	at := 0
	for page in wire.command.ctx.pages {
		for item in page.tracks {
			if !started {
				started =
					event.target_uid != "" ? item.uid == event.target_uid : event.target_uri != "" ? item.uri == event.target_uri : at == event.target_index
				if started && len(event.tracks) > 0 {at += 1; continue}
			}
			if started {_ = append_uri(event, item.uri)}
			at += 1
		}
	}
	return len(event.tracks) > 0
}
