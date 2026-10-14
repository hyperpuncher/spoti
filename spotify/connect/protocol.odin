// Native Connect state wire format. Field numbers come from librespot's
// connect.proto, player.proto and transfer_state.proto. Never log payloads.
package connect

import ap "../ap"
import oauth "../oauth"
import track "../track"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

MAX_TRACKS :: 80

Action :: enum {
	Load,
	Resume,
	Pause,
	Seek,
	Next,
	Previous,
	Volume,
	Options,
	Inactive,
}

Event :: struct {
	action:                                            Action,
	key:                                               string,
	context_uri:                                       string,
	target_uri, target_uid:                            string,
	target_index:                                      int,
	tracks:                                            [dynamic]string,
	position:                                          int,
	paused:                                            bool,
	volume:                                            f32,
	shuffle, repeat_context, repeat_track:             bool,
	set_shuffle, set_repeat_context, set_repeat_track: bool,
}

free_event :: proc(event: Event) {
	delete(event.key)
	delete(event.context_uri)
	delete(event.target_uri)
	delete(event.target_uid)
	for uri in event.tracks {delete(uri)}
	delete(event.tracks)
}

Snapshot :: struct {
	uri, context_uri:                      string,
	tracks:                                [dynamic]string,
	index:                                 int,
	queue_revision:                        u64,
	position, duration:                    int,
	active:                                bool,
	playing, paused, buffering:            bool,
	volume:                                f32,
	shuffle, repeat_context, repeat_track: bool,
}

free_snapshot :: proc(snapshot: ^Snapshot) {
	delete(snapshot.uri)
	delete(snapshot.context_uri)
	for uri in snapshot.tracks {delete(uri)}
	delete(snapshot.tracks)
	snapshot^ = {}
}

// Fixed64 little-endian double for PlayerState.playback_speed.
put_double :: proc(out: ^[dynamic]u8, field: u64, value: f64) {
	ap.put_varint(out, field << 3 | 1)
	bytes := transmute([8]u8)u64le(transmute(u64)value)
	append(out, ..bytes[:])
}

put_string :: proc(out: ^[dynamic]u8, field: u64, value: string) {
	ap.put_bytes(out, field, transmute([]u8)value)
}

encode_state :: proc(
	device_id, session_id: string,
	snapshot: Snapshot,
	reason: u64,
	last_sender: string = "",
	last_message: u32 = 0,
) -> [dynamic]u8 {
	capabilities := make([dynamic]u8)
	defer delete(capabilities)
	for field in ([]u64{2, 5, 7, 10, 15, 16, 19, 20, 22, 23, 25}) {ap.put_number(&capabilities, field, 1)}
	ap.put_number(&capabilities, 8, 100)
	put_string(&capabilities, 9, "audio/track")
	ap.put_number(&capabilities, 30, 4) // VERY_HIGH
	info := make([dynamic]u8)
	defer delete(info)
	ap.put_number(&info, 1, 1)
	ap.put_number(&info, 2, u64(clamp(snapshot.volume, 0, 1) * 65535))
	put_string(&info, 3, "spoti")
	ap.put_bytes(&info, 4, capabilities[:])
	put_string(&info, 6, "0.1.0")
	ap.put_number(&info, 7, 1) // COMPUTER
	put_string(&info, 9, "3.2.6")
	put_string(&info, 10, device_id)
	put_string(&info, 13, oauth.PLAYBACK_CLIENT_ID)
	options := make([dynamic]u8)
	defer delete(options)
	ap.put_number(&options, 1, u64(snapshot.shuffle))
	ap.put_number(&options, 2, u64(snapshot.repeat_context))
	ap.put_number(&options, 3, u64(snapshot.repeat_track))
	player := make([dynamic]u8)
	defer delete(player)
	now := u64(time.time_to_unix_nano(time.now()) / 1_000_000)
	ap.put_number(&player, 1, now)
	put_double(&player, 9, snapshot.playing ? 1 : 0)
	ap.put_number(&player, 10, u64(max(snapshot.position, 0)))
	ap.put_number(&player, 11, u64(max(snapshot.duration, 0)))
	ap.put_number(&player, 12, u64(snapshot.playing || snapshot.paused || snapshot.buffering))
	ap.put_number(&player, 13, u64(snapshot.paused || !snapshot.playing && !snapshot.buffering))
	ap.put_number(&player, 14, u64(snapshot.paused || snapshot.buffering))
	ap.put_number(&player, 15, 1)
	ap.put_bytes(&player, 16, options[:])
	put_string(&player, 23, session_id)
	if snapshot.context_uri != "" {put_string(&player, 2, snapshot.context_uri)}
	if snapshot.uri != "" {
		provided := make([dynamic]u8)
		defer delete(provided)
		put_string(&provided, 1, snapshot.uri)
		put_string(&provided, 6, "context")
		ap.put_bytes(&player, 7, provided[:])
	}
	if len(snapshot.tracks) > 0 {
		index := clamp(snapshot.index, 0, len(snapshot.tracks) - 1)
		context_index := make([dynamic]u8)
		defer delete(context_index)
		ap.put_number(&context_index, 2, u64(index))
		ap.put_bytes(&player, 6, context_index[:])
		for uri, track_index in snapshot.tracks {
			if track_index == index {continue}
			provided := make([dynamic]u8)
			put_string(&provided, 1, uri)
			put_string(&provided, 6, "context")
			ap.put_bytes(&player, track_index < index ? 19 : 20, provided[:])
			delete(provided)
		}
		revision := fmt.aprintf("%d", snapshot.queue_revision, allocator = context.temp_allocator)
		put_string(&player, 24, revision)
	}
	device := make([dynamic]u8)
	defer delete(device)
	ap.put_bytes(&device, 1, info[:])
	ap.put_bytes(&device, 2, player[:])
	out := make([dynamic]u8)
	ap.put_bytes(&out, 2, device[:])
	ap.put_number(&out, 3, 2) // CONNECT_STATE
	ap.put_number(&out, 4, u64(snapshot.active))
	ap.put_number(&out, 5, reason)
	put_string(&out, 7, last_sender)
	ap.put_number(&out, 8, u64(last_message))
	ap.put_number(&out, 12, now)
	return out
}

append_uri :: proc(event: ^Event, uri: string) -> bool {
	if len(event.tracks) >= MAX_TRACKS {return false}
	if _, valid := track.parse_id(uri); !valid {return false}
	append(&event.tracks, strings.clone(uri))
	return true
}

// Current track and position are required; a transfer without a playable
// track must not be acknowledged as accepted.
parse_transfer :: proc(data: []u8) -> (event: Event, ok: bool) {
	event.action = .Load
	defer if !ok {free_event(event); event = {}}
	playback, found, valid := ap.get_bytes(data, 2)
	if !found || !valid {return}
	current, has_track, track_valid := ap.get_bytes(playback, 5)
	if !has_track || !track_valid {return}
	uri, _, uri_valid := ap.get_bytes(current, 1)
	if !uri_valid {return}
	current_uri := string(uri)
	if current_uri == "" {
		gid, _, gid_valid := ap.get_bytes(current, 3)
		if !gid_valid || len(gid) != 16 {return}
		id: [16]u8
		copy(id[:], gid)
		current_uri = fmt.aprintf(
			"spotify:track:%s",
			track.base62_id(id, context.temp_allocator),
			allocator = context.temp_allocator,
		)
	}
	if !append_uri(&event, current_uri) {return}
	event.target_uri = strings.clone(current_uri)
	uid, _, uid_valid := ap.get_bytes(current, 2)
	if !uid_valid {return}
	event.target_uid = strings.clone(string(uid))
	position, _, position_valid := ap.get_number(playback, 2)
	paused, _, paused_valid := ap.get_number(playback, 4)
	if !position_valid || !paused_valid || position > u64(max(i32)) {return}
	event.position, event.paused = int(position), paused != 0
	stamp, _, stamp_valid := ap.get_number(playback, 1)
	if !stamp_valid {return}
	if !event.paused && event.position > 0 && stamp > 0 {
		now := time.time_to_unix_nano(time.now()) / 1_000_000
		event.position += int(clamp(now - i64(stamp), 0, 30000))
	}
	options, _, options_valid := ap.get_bytes(data, 1)
	if !options_valid {return}
	shuffle, _, _ := ap.get_number(options, 1)
	repeat_context, _, _ := ap.get_number(options, 2)
	repeat_track, _, _ := ap.get_number(options, 3)
	event.shuffle, event.repeat_context, event.repeat_track =
		shuffle != 0, repeat_context != 0, repeat_track != 0
	queue, _, queue_valid := ap.get_bytes(data, 4)
	if !queue_valid {return}
	pos := 0
	for pos < len(queue) && len(event.tracks) < MAX_TRACKS {
		field, wire, item, _, item_valid := ap.next_field(queue, &pos)
		if !item_valid {return}
		if field == 1 && wire == 2 {
			queued_uri, _, queued_valid := ap.get_bytes(item, 1)
			if queued_valid {_ = append_uri(&event, string(queued_uri))}
		}
	}
	current_session, _, session_valid := ap.get_bytes(data, 3)
	if !session_valid {return}
	ctx, _, ctx_valid := ap.get_bytes(current_session, 2)
	if !ctx_valid {return}
	context_uri, _, context_valid := ap.get_bytes(ctx, 1)
	if !context_valid {return}
	event.context_uri = strings.clone(string(context_uri))
	ok = true
	return
}

Context :: struct {
	uri:   string,
	pages: []struct {
		tracks: []struct {
			uri, uid: string,
		},
	},
}

// A transfer already carries its current track and any explicit queue.
// A play request starts empty. Both select the same context position.
append_context :: proc(event: ^Event, ctx: Context) {
	skip_current := len(event.tracks) > 0
	started := false
	at := 0
	for page in ctx.pages {
		for item in page.tracks {
			if len(event.tracks) >= MAX_TRACKS {return}
			if !started {
				switch {
				case event.target_uid != "":
					started = item.uid == event.target_uid
				case event.target_uri != "":
					started = item.uri == event.target_uri
				case:
					started = at == event.target_index
				}
				if started && skip_current {at += 1; continue}
			}
			if started {_ = append_uri(event, item.uri)}
			at += 1
		}
	}
}

Request :: struct {
	// Some Spotify clients send null or string Dealer metadata.
	message_id, sent_by_device_id: json.Value,
	command:                       struct {
		endpoint:                                              string,
		data:                                                  string,
		value:                                                 json.Value,
		ctx:                                                   Context `json:"context"`,
		options:                                               struct {
			seek_to:          int,
			initially_paused: bool,
			skip_to:          struct {
				track_uri:   string,
				track_uid:   string,
				track_index: int,
			},
		},
		shuffling_context, repeating_context, repeating_track: json.Value,
	},
}

request_message_id :: proc(request: Request) -> u32 {
	if value, integer := request.message_id.(json.Integer);
	   integer && value >= 0 && value <= i64(max(u32)) {return u32(value)}
	if value, text := request.message_id.(json.String); text {
		parsed, ok := strconv.parse_u64(value)
		if ok && parsed <= u64(max(u32)) {return u32(parsed)}
	}
	return 0
}

request_sender :: proc(request: Request) -> string {
	value, valid := request.sent_by_device_id.(json.String)
	return valid ? value : ""
}

parse_command :: proc(body: []u8) -> (event: Event, request: Request, ok: bool) {
	// Transport controls need only the endpoint. Parse that first because
	// clients can attach nullable fields that belong to other commands.
	header: struct {
		message_id, sent_by_device_id: json.Value,
		command:                       struct {
			endpoint: string,
		},
	}
	if json.unmarshal(body, &header, allocator = context.temp_allocator) != nil {return}
	request.message_id = header.message_id
	request.sent_by_device_id = header.sent_by_device_id
	request.command.endpoint = header.command.endpoint
	switch header.command.endpoint {
	case "pause":
		event.action, ok = .Pause, true; return
	case "resume":
		event.action, ok = .Resume, true; return
	case "skip_next":
		event.action, ok = .Next, true; return
	case "skip_prev":
		event.action, ok = .Previous, true; return
	}
	if json.unmarshal(body, &request, allocator = context.temp_allocator) != nil {return}
	switch request.command.endpoint {
	case "transfer":
		data, error := base64.decode(request.command.data, allocator = context.temp_allocator)
		if error != nil {return}
		event, ok = parse_transfer(data)
		return
	case "play":
		event.action = .Load
		event.position = max(request.command.options.seek_to, 0)
		event.paused = request.command.options.initially_paused
		event.context_uri = strings.clone(request.command.ctx.uri)
		event.target_uri = strings.clone(request.command.options.skip_to.track_uri)
		event.target_uid = strings.clone(request.command.options.skip_to.track_uid)
		event.target_index = max(request.command.options.skip_to.track_index, 0)
		append_context(&event, request.command.ctx)
		ok = len(event.tracks) > 0 || event.context_uri != ""
	case "seek_to":
		if value, valid := request.command.value.(json.Integer);
		   valid && value >= 0 && value <= i64(max(i32)) {
			event.action, event.position, ok = .Seek, int(value), true
		}
	case "set_shuffling_context", "set_repeating_context", "set_repeating_track":
		if value, valid := request.command.value.(bool); valid {
			event.action = .Options
			switch request.command.endpoint {
			case "set_shuffling_context":
				event.shuffle, event.set_shuffle = value, true
			case "set_repeating_context":
				event.repeat_context, event.set_repeat_context = value, true
			case "set_repeating_track":
				event.repeat_track, event.set_repeat_track = value, true
			}
			ok = true
		}
	case "set_options":
		event.action = .Options
		event.shuffle, event.set_shuffle = request.command.shuffling_context.(bool)
		event.repeat_context, event.set_repeat_context = request.command.repeating_context.(bool)
		event.repeat_track, event.set_repeat_track = request.command.repeating_track.(bool)
		ok = event.set_shuffle || event.set_repeat_context || event.set_repeat_track
	case:
	// Unimplemented queue/context commands get a failure reply, not a
	// false success. The device must report only what it actually did.
	}
	return
}
