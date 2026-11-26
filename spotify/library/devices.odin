// Spotify Connect devices: which hardware can take playback, which one is
// active, and the transfer call that moves playback between them.
package library

import diagnostic "../../diagnostic"
import http "../http"
import "core:encoding/json"
import "core:strings"

DEVICES_ADDRESS :: "https://api.spotify.com/v1/me/player/devices"
TRANSFER_ADDRESS :: "https://api.spotify.com/v1/me/player"
PLAYER_ADDRESS :: "https://api.spotify.com/v1/me/player"

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

// Device ids are opaque server strings. Reject empty, oversized, or malformed ids.
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

// Live state of the API-active playback: whether it plays, where it is,
// and on which device. A 204 means nothing is active anywhere.
Player_State :: struct {
	playing:    bool,
	progress:   int,
	device:     string, // owned; active device name
	device_id:  string, // owned; empty if Spotify does not expose a usable id
	restricted: bool,
	uri:        string, // owned; active track or episode
	title:      string, // owned; active track or episode
	artist:     string, // owned
	cover:      string, // owned
	duration:   int, // milliseconds
}

player_wire :: struct {
	is_playing:  bool,
	progress_ms: int,
	device:      player_device_wire,
	item:        player_item_wire,
}

player_item_wire :: struct {
	uri:         string,
	name:        string,
	duration_ms: int,
	artists:     []Artist,
	album:       struct {
		images: []Image,
	},
	images:      []Image, // episodes carry their own image
	show:        struct {
		name: string,
	},
}

player_device_wire :: struct {
	id:            string,
	name:          string,
	is_active:     bool,
	is_restricted: bool,
}

// Parses a playback-state payload into a caller-owned state. Entries
// without an active device fail the parse.
parse_player_state :: proc(body: []u8) -> (state: Player_State, ok: bool) {
	wire: player_wire
	if json.unmarshal(body, &wire, allocator = context.temp_allocator) != nil {return {}, false}
	if len(wire.device.name) == 0 || !wire.device.is_active {return {}, false}
	item := wire.item
	images := item.album.images
	if len(images) == 0 {images = item.images}
	artist := item.show.name
	if len(item.artists) != 0 {artist = joined_artists(item.artists, context.temp_allocator)}
	return Player_State {
			playing = wire.is_playing,
			progress = max(wire.progress_ms, 0),
			device = strings.clone(wire.device.name),
			device_id = valid_device_id(wire.device.id) ? strings.clone(wire.device.id) : "",
			restricted = wire.device.is_restricted,
			uri = strings.clone(item.uri),
			title = strings.clone(item.name),
			artist = strings.clone(artist),
			cover = strings.clone(cover_url(images)),
			duration = max(0, item.duration_ms),
		},
		true
}

fetch_player_state :: proc(
	access: string,
	reuse: rawptr = nil,
) -> (
	state: Player_State,
	status: int,
	ok: bool,
) {
	body, code, fetched := http.get(PLAYER_ADDRESS, {bearer = access, limit = 64 * 1024}, reuse)
	defer delete(body)
	if !fetched || (code != 200 && code != 204) {
		diagnostic.writef("connect player fetch status=%d fetched=%v", code, fetched)
		return {}, code, false
	}
	if code == 204 {return {}, code, false}
	state, ok = parse_player_state(body[:])
	if !ok {
		diagnostic.writef("connect player parse status=%d bytes=%d", code, len(body))
		return {}, code, false
	}
	diagnostic.writef(
		"connect player status=%d playing=%v progress=%d",
		code,
		state.playing,
		state.progress,
	)
	return state, code, true
}
// Frees an owned player state.
free_player_state :: proc(state: Player_State) {
	delete(state.device)
	delete(state.device_id)
	delete(state.uri)
	delete(state.title)
	delete(state.artist)
	delete(state.cover)
}

@(private)
transfer_body :: proc(device_id: string, play: bool) -> (body: []u8, ok: bool) {
	if !valid_device_id(device_id) {return}
	payload := struct {
		device_ids: [1]string,
		play:       bool,
	} {
		device_ids = {device_id},
		play       = play,
	}
	data, err := json.marshal(payload, allocator = context.temp_allocator)
	return data, err == nil
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
	body, built := transfer_body(device_id, play)
	if !built {return 0, false}
	response, code, sent := http.json_request(
		"PUT",
		TRANSFER_ADDRESS,
		string(body),
		{bearer = access},
		reuse,
	)
	defer delete(response)
	return code, sent && code == 204
}
