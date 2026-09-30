// Persistent AP login, track metadata, keys and CDN resolution, shared by
// the diagnostic, playback and next-track preload workers.
package session

import ap "../ap"
import audio "../audio"
import http "../http"
import oauth "../oauth"
import track "../track"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:sync"

TRACK_URL :: "https://open.spotify.com/track/1TifAMm1r1MascYZ5xGiQk"

Source :: struct {
	name:        string,
	format:      track.Audio_Format,
	duration_ms: int,
	key:         [16]u8,
	file_id:     [20]u8,
	storage:     [dynamic]u8, // contains the signed URL, never print it
	url:         string, // view into storage
}

close_source :: proc(source: ^Source) {
	crypto.zero_explicit(&source.key, size_of(source.key))
	crypto.zero_explicit(raw_data(source.storage), len(source.storage))
	delete(source.storage)
	delete(source.name)
	source^ = {}
}

// Only encrypted audio ranges may be cached on disk. Audio keys and signed
// URLs stay in memory; refresh grants require explicit keyring opt-in.
// Never print the callback URL or any tokens.
Keyring_Mode :: enum {
	None,
	Restore,
	Remember,
}

open :: proc(
	keyring_mode: Keyring_Mode = .None,
	cancel: ^bool = nil,
	track_url: string = TRACK_URL,
) -> (
	source: Source,
	ok: bool,
) {
	defer if !ok {close_source(&source)}
	id, valid := track.parse_id(track_url)
	if !valid {fmt.eprintln("invalid Spotify track link or URI"); return}
	tokens, authorized := authorize(keyring_mode, cancel)
	if !authorized {return}
	defer oauth.wipe_tokens(&tokens)
	source, ok = resolve_ap_source(tokens.access, id, cancel)
	if !ok {return}
	ok = false
	if cancelled(cancel) {return}
	file_hex := hex.encode(source.file_id[:])
	defer delete(file_hex)
	endpoint := fmt.aprintf(
		"https://spclient.wg.spotify.com/storage-resolve/files/audio/interactive/%s",
		string(file_hex),
	)
	defer delete(endpoint)
	storage, status, fetched := http.get(endpoint, {bearer = tokens.access, cancel = cancel})
	source.storage = storage
	if !fetched {fmt.eprintln("CDN resolver request failed"); return}
	if status != 200 {fmt.eprintln("CDN resolver returned HTTP", status); return}
	source.url, ok = audio.cdn_url(storage[:], source.file_id)
	if !ok {fmt.eprintln("CDN resolver did not return a usable URL"); return}
	fmt.println("CDN URL resolved.")
	return source, true
}

resolve_ap_source :: proc(access: string, id: [16]u8, cancel: ^bool) -> (Source, bool) {
	if !lock_connection(cancel) {return {}, false}
	defer sync.unlock(&connection_mutex)
	if !start_connection_worker() {return {}, false}
	return resolve_ap_connection(&connection, access, id, cancel)
}

resolve_ap_connection :: proc(
	c: ^AP_Connection,
	access: string,
	id: [16]u8,
	cancel: ^bool,
	connect: proc(_: ^AP_Connection, _: string, _: ^bool) -> bool = connect_connection,
) -> (
	Source,
	bool,
) {
	for attempt in 0 ..< 2 {
		if cancelled(cancel) {close_connection(c); return {}, false}
		reused := c.connected
		if !c.connected && !connect(c, access, cancel) {return {}, false}
		source, ok := fetch_ap_source(c, id, cancel)
		if ok {return source, true}
		broken := c.broken
		// Drop a canceled transaction, including any unread late replies.
		close_connection(c)
		if !reused || !broken || cancelled(cancel) || attempt == 1 {return {}, false}
	}
	return {}, false
}

fetch_ap_source :: proc(
	c: ^AP_Connection,
	id: [16]u8,
	cancel: ^bool,
) -> (
	source: Source,
	ok: bool,
) {
	defer if !ok {close_source(&source)}
	if cancelled(cancel) || c.sequence == max(u32) {return}
	sequence := c.sequence
	c.sequence += 1
	track_hex := track.hex_id(id)
	defer delete(track_hex)
	uri := fmt.aprintf("hm://metadata/4/track/%s", track_hex)
	defer delete(uri)
	request := ap.mercury_get(uri, u64(sequence))
	defer delete(request)
	if !send_connection_packet(c, 0xb2, request[:]) {return}
	got_metadata := false
	for _ in 0 ..< 64 {
		command, reply, received := read_connection_reply(c, cancel)
		if !received {return}
		defer delete(reply)
		if command != 0xb2 {continue}
		payload, code, parsed := ap.mercury_body(reply, u64(sequence))
		if !parsed ||
		   code != 200 {fmt.eprintln("track metadata response invalid or refused:", code); return}
		metadata, valid := track.parse_metadata(payload, id)
		if !valid {fmt.eprintln("no supported playable Vorbis file in metadata"); return}
		source.name = strings.clone(metadata.name)
		source.format, source.file_id, source.duration_ms =
			metadata.format, metadata.file_id, metadata.duration_ms
		got_metadata = true
		break
	}
	if !got_metadata || cancelled(cancel) {return}
	key_request := ap.request_audio_key(source.file_id, id, sequence)
	if !send_connection_packet(c, 0x0c, key_request[:]) {return}
	for _ in 0 ..< 64 {
		command, reply, received := read_connection_reply(c, cancel)
		if !received {return}
		defer {crypto.zero_explicit(raw_data(reply), len(reply)); delete(reply)}
		if command != 0x0d && command != 0x0e {continue}
		result: ap.Audio_Key_Result
		source.key, result = ap.read_audio_key(command, reply, sequence)
		if result != .Granted {fmt.eprintln("audio key refused or invalid"); return}
		if cancelled(cancel) {return}
		return source, true
	}
	return
}

// Optional first-range check, used by the non-playing diagnostic.
probe :: proc(source: ^Source) -> bool {
	chunk, status, fetched := http.get(source.url, {range = "0-65535", limit = 65536})
	if !fetched {fmt.eprintln("CDN audio range request failed"); return false}
	defer {crypto.zero_explicit(raw_data(chunk), len(chunk)); delete(chunk)}
	if status != 206 ||
	   len(chunk) < 171 {fmt.eprintln("CDN audio range invalid:", status); return false}
	dec := audio.init(source.key)
	defer audio.reset(&dec)
	audio.process(&dec, chunk[:])
	if string(chunk[0xa7:0xab]) !=
	   "OggS" {fmt.eprintln("decrypted range lacked Ogg header"); return false}
	fmt.println("audio range decrypted and Ogg header verified. No playback yet.")
	return true
}
