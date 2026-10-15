// Spotify's resolver supplies the active access points in preferred order.
package ap

import http "../http"
import "core:encoding/json"
import "core:net"
import "core:strings"
import "core:sync"

Resolve_Result :: enum {
	Connected,
	Unavailable,
	Invalid_Response,
	Connection_Failed,
	Cancelled,
}

parse_access_points :: proc(body: []u8) -> (addresses: []string, ok: bool) {
	reply: struct {
		accesspoint: []string,
	}
	if json.unmarshal(body, &reply, allocator = context.temp_allocator) != nil {return}
	if len(reply.accesspoint) == 0 || len(reply.accesspoint) > 8 {return}
	for address in reply.accesspoint {
		target, err := net.parse_hostname_or_endpoint(address)
		if err != nil {return nil, false}
		switch host in target {
		case net.Host:
			if !strings.has_suffix(host.hostname, ".spotify.com") ||
			   host.port != 4070 && host.port != 443 && host.port != 80 {return nil, false}
		case net.Endpoint:
			return nil, false
		}
	}
	return reply.accesspoint, true
}

connect :: proc(
	cancel: ^bool = nil,
	fetch: type_of(http.get) = http.get,
) -> (
	socket: net.TCP_Socket,
	result: Resolve_Result,
) {
	if cancel != nil && sync.atomic_load(cancel) {return {}, .Cancelled}
	body, status, fetched := fetch(
		"https://apresolve.spotify.com/?type=accesspoint",
		{limit = 16 * 1024, cancel = cancel},
	)
	defer delete(body)
	if cancel != nil && sync.atomic_load(cancel) {return {}, .Cancelled}
	if !fetched || status != 200 {return {}, .Unavailable}
	addresses, valid := parse_access_points(body[:])
	if !valid {return {}, .Invalid_Response}
	for address in addresses {
		if cancel != nil && sync.atomic_load(cancel) {return {}, .Cancelled}
		connected, err := net.dial_tcp(address)
		if err == nil {return connected, .Connected}
	}
	return {}, .Connection_Failed
}
