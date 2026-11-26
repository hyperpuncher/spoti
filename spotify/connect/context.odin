package connect

import session "../session"

// Fill a transfer from its playback context after any explicit queued items.
// A transfer can still play its supplied track if context resolution fails.
resolve_context :: proc(client: ^Client, access: string, event: ^Event, reuse: rawptr) -> bool {
	if event.context_uri != "" && event.context_uri != "-" {
		if ctx, _, ok := session.fetch_context(access, event.context_uri, &client.cancel, reuse);
		   ok {
			append_context(event, ctx)
		}
	}
	return len(event.tracks) > 0
}
