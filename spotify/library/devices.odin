// Spotify Connect devices: which hardware can take playback, which one is
// active, and the transfer call that moves playback between them.
package library

import diagnostic "../../diagnostic"
import http "../http"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

DEVICES_ADDRESS :: "https://api.spotify.com/v1/me/player/devices"
TRANSFER_ADDRESS :: "https://api.spotify.com/v1/me/player"

// One Connect device. Strings are caller-owned; volume is -1 when the
// device reports none.
Device :: struct {
	id:         string,
	name:       string,
	type:       string,
	active:     bool,
	restricted: bool,
	volume:     int,
}

// Device ids are opaque server strings; anything with a quote, a
// backslash or a control byte is rejected instead of escaped.
valid_device_id :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 128 {return false}
	for ch in transmute([]u8)id {
		if ch < 0x20 || ch == '"' || ch == '\\' {return false}
	}
	return true
}

device_response :: struct {
	devices: []device_wire,
}

device_wire :: struct {
	id:             string,
	name:           string,
	type:           string,
	is_active:      bool,
	is_restricted:  bool,
	volume_percent: json.Value,
}

// Parses a devices payload into caller-owned devices. Entries with a bad
// id are skipped; a bad payload fails the whole parse.
parse_devices :: proc(body: []u8) -> (devices: [dynamic]Device, ok: bool) {
	response: device_response
	if json.unmarshal(body, &response, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	devices = make([dynamic]Device, context.allocator)
	for wire in response.devices {
		if !valid_device_id(wire.id) {continue}
		volume := -1
		if number, is_number := wire.volume_percent.(json.Integer); is_number {
			volume = int(number)
		}
		append(
			&devices,
			Device {
				id = strings.clone(wire.id),
				name = strings.clone(wire.name),
				type = strings.clone(wire.type),
				active = wire.is_active,
				restricted = wire.is_restricted,
				volume = volume,
			},
		)
	}
	return devices, true
}

free_devices :: proc(devices: [dynamic]Device) {
	for device in devices {
		delete(device.id)
		delete(device.name)
		delete(device.type)
	}
	delete(devices)
}

fetch_devices :: proc(
	access: string,
	reuse: rawptr = nil,
) -> (
	devices: [dynamic]Device,
	status: int,
	ok: bool,
) {
	body, code, fetched := http.get(DEVICES_ADDRESS, {bearer = access, limit = 64 * 1024}, reuse)
	defer delete(body)
	if !fetched || code != 200 {
		diagnostic.writef("connect devices fetch status=%d fetched=%v", code, fetched)
		return nil, code, false
	}
	devices, ok = parse_devices(body[:])
	diagnostic.writef(
		"connect devices parse status=%d bytes=%d devices=%d ok=%v",
		code,
		len(body),
		len(devices),
		ok,
	)
	if !ok {
		free_devices(devices)
		return nil, code, false
	}
	return devices, code, true
}

// Moves playback to one device. Play starts it there when true, otherwise
// the current play state carries over. Device id and body are validated,
// never logged.
transfer_playback :: proc(
	access, device_id: string,
	play: bool,
	reuse: rawptr = nil,
) -> (
	status: int,
	ok: bool,
) {
	if !valid_device_id(device_id) {return 0, false}
	body := fmt.aprintf(`{"device_ids":["%s"],"play":%v}`, device_id, play, context.temp_allocator)
	response, code, sent := http.put_json(TRANSFER_ADDRESS, body, {bearer = access}, reuse)
	defer delete(response)
	diagnostic.writef("connect transfer status=%d ok=%v", code, sent)
	return code, sent && code == 204
}
