// One-track Spotify session. Login, track metadata, key and CDN resolution
// are shared by the diagnostic and the streaming player.
package session

import ap "../ap"
import audio "../audio"
import credential "../credential"
import http "../http"
import oauth "../oauth"
import track "../track"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

TRACK_URL :: "https://open.spotify.com/track/1TifAMm1r1MascYZ5xGiQk"

Source :: struct {
	name:        string,
	format:      track.Audio_Format,
	duration_ms: int,
	key:         [16]u8,
	storage:     [dynamic]u8, // contains the signed URL, never print it
	url:         string, // view into storage
}

close_source :: proc(source: ^Source) {
	crypto.zero_explicit(&source.key, size_of(source.key))
	crypto.zero_explicit(raw_data(source.storage), len(source.storage))
	delete(source.storage)
	delete(source.name)
}

// Make one authenticated session. Audio is never saved on disk; with explicit
// opt-in, only a refresh grant is saved in the system keyring. Never print the
// callback URL or any tokens.
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
	id, valid_id := track.parse_id(track_url)
	if !valid_id {fmt.eprintln("invalid Spotify track link or URI"); return}
	tokens: oauth.Tokens
	defer oauth.wipe_tokens(&tokens)
	have_token := false
	if keyring_mode != .None {
		if stored, found := credential.load(); found {
			fresh, result := oauth.refresh(stored)
			crypto.zero_explicit(raw_data(stored), len(stored))
			delete(stored)
			switch result {
			case .Authorized:
				tokens = fresh
				have_token = true
				if len(tokens.refresh) > 0 && !credential.save(tokens.refresh) {
					fmt.eprintln(
						"keyring did not save rotated sign-in; you may need browser approval next time",
					)
				}
				fmt.println("Spotify sign-in restored from the system keyring")
			case .Rejected:
				credential.clear() // revoked grant; ask the user to sign in again
			case .Network_Error, .Invalid_Response:
				fmt.eprintln(
					"could not refresh saved sign-in; try again when Spotify is reachable",
				)
				return
			}
		}
	}
	if !have_token {
		listener, ready := oauth.listen()
		if !ready {fmt.eprintln("cannot listen on 127.0.0.1:8898 (is another player using it?)"); return}
		defer net.close(listener)
		flow := oauth.begin()
		defer {
			crypto.zero_explicit(raw_data(flow.verifier), len(flow.verifier))
			delete(flow.verifier)
			delete(flow.state)
			delete(flow.url)
		}
		fmt.println("Open this URL in your browser to approve Spotify streaming:")
		fmt.println(flow.url)
		fmt.println("Waiting up to ten minutes for the local redirect. Ctrl+C cancels.")
		code, result := oauth.wait_for_code(listener, flow.state, cancel)
		if result != .Authorized {
			if result != .Cancelled {fmt.eprintln("browser approval did not complete:", result)}
			return
		}
		defer {crypto.zero_explicit(raw_data(code), len(code)); delete(code)}
		new_tokens, status := oauth.exchange_code(code, flow.verifier)
		if status != .Authorized {fmt.eprintln("token exchange did not complete:", status); return}
		tokens = new_tokens
		if keyring_mode == .Remember {
			if len(tokens.refresh) == 0 || !credential.save(tokens.refresh) {
				fmt.eprintln(
					"system keyring unavailable; browser approval will be needed next time",
				)
			} else {
				fmt.println("sign-in saved in the system keyring; use 'just logout' to remove it")
			}
		}
	}

	if cancel != nil && sync.atomic_load(cancel) {return}
	socket, err := net.dial_tcp("ap.spotify.com:443")
	if err != nil {fmt.eprintln("could not reach Spotify access point:", err); return}
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, time.Duration(8 * time.Second))
	_ = net.set_option(socket, .Send_Timeout, time.Duration(8 * time.Second))
	keys, handshake_error := ap.handshake(socket)
	if handshake_error != .None {fmt.eprintln("AP handshake failed:", handshake_error); return}
	defer crypto.zero_explicit(&keys, size_of(keys))
	sender := ap.packet_cipher(keys.send[:])
	receiver := ap.packet_cipher(keys.receive[:])
	defer {
		crypto.zero_explicit(&sender, size_of(sender))
		crypto.zero_explicit(&receiver, size_of(receiver))
	}
	device_bytes: [20]u8
	crypto.rand_bytes(device_bytes[:])
	device_id := hex.encode(device_bytes[:])
	crypto.zero_explicit(&device_bytes, size_of(device_bytes))
	defer delete(device_id)
	body := ap.client_login_token(tokens.access, string(device_id))
	defer {crypto.zero_explicit(raw_data(body), len(body)); delete(body)}
	packet := ap.seal_packet(&sender, 0xab, body[:])
	defer {crypto.zero_explicit(raw_data(packet), len(packet)); delete(packet)}
	if packet == nil ||
	   !ap.send_full(socket, packet[:]) {fmt.eprintln("AP login could not be sent"); return}
	command, response, received := ap.read_packet(socket, &receiver)
	if !received {fmt.eprintln("AP login response missing or invalid MAC"); return}
	defer {crypto.zero_explicit(raw_data(response), len(response)); delete(response)}
	_, failure, kind := ap.parse_login_reply(command, response)
	switch kind {
	case .Welcome:
		fmt.println("AP login accepted. No audio playback yet.")
	case .Failure:
		fmt.eprintln("AP login refused; Spotify error code:", failure); return
	case .Invalid:
		fmt.eprintln("unexpected AP login response"); return
	}

	track_hex := track.hex_id(id)
	defer delete(track_hex)
	uri := fmt.aprintf("hm://metadata/4/track/%s", track_hex)
	defer delete(uri)
	request := ap.mercury_get(uri, 0)
	defer delete(request)
	wire := ap.seal_packet(&sender, 0xb2, request[:])
	defer delete(wire)
	if wire == nil ||
	   !ap.send_full(
			   socket,
			   wire[:],
		   ) {fmt.eprintln("track metadata request could not be sent"); return}
	metadata: track.Metadata
	got_metadata := false
	for _ in 0 ..< 12 {
		cmd, reply, received := ap.read_packet(socket, &receiver)
		if !received {fmt.eprintln("track metadata response missing or invalid MAC"); return}
		defer delete(reply)
		if cmd == 0x04 {send_pong(socket, &sender); continue}
		if cmd != 0xb2 {continue}
		payload, code, parsed := ap.mercury_body(reply, 0)
		if !parsed ||
		   code != 200 {fmt.eprintln("track metadata response invalid or refused:", code); return}
		metadata, got_metadata = track.parse_metadata(payload, id)
		if !got_metadata {fmt.eprintln("no supported playable Vorbis file in metadata"); return}
		source.name = strings.clone(metadata.name)
		source.format = metadata.format
		source.duration_ms = metadata.duration_ms
		break
	}
	if !got_metadata {fmt.eprintln("track metadata reply not seen"); return}
	if cancel != nil && sync.atomic_load(cancel) {return}
	fmt.println("track metadata found:", source.name, "(Vorbis format", source.format, ")")

	key_request := ap.request_audio_key(metadata.file_id, id, 0)
	key_packet := ap.seal_packet(&sender, 0x0c, key_request[:])
	defer delete(key_packet)
	if key_packet == nil ||
	   !ap.send_full(
			   socket,
			   key_packet[:],
		   ) {fmt.eprintln("audio key request could not be sent"); return}
	got_key := false
	for _ in 0 ..< 12 {
		cmd, reply, received := ap.read_packet(socket, &receiver)
		if !received {fmt.eprintln("audio key response missing or invalid MAC"); return}
		defer {crypto.zero_explicit(raw_data(reply), len(reply)); delete(reply)}
		if cmd == 0x04 {send_pong(socket, &sender); continue}
		if cmd != 0x0d && cmd != 0x0e {continue}
		key_result: ap.Audio_Key_Result
		source.key, key_result = ap.read_audio_key(cmd, reply, 0)
		switch key_result {
		case .Granted:
			got_key = true
		case .Refused:
			fmt.eprintln("Spotify refused the audio key"); return
		case .Invalid:
			fmt.eprintln("invalid audio key reply"); return
		}
		break
	}
	if !got_key {fmt.eprintln("audio key reply not seen"); return}
	if cancel != nil && sync.atomic_load(cancel) {return}
	fmt.println("audio key granted.")

	file_hex := hex.encode(metadata.file_id[:])
	defer delete(file_hex)
	endpoint := fmt.aprintf(
		"https://spclient.wg.spotify.com/storage-resolve/files/audio/interactive/%s",
		string(file_hex),
	)
	defer delete(endpoint)
	storage, status_code, fetched := http.get(endpoint, {bearer = tokens.access})
	if !fetched {fmt.eprintln("CDN resolver request failed"); return}
	source.storage = storage
	if status_code != 200 {fmt.eprintln("CDN resolver returned HTTP", status_code); return}
	resolved: bool
	source.url, resolved = audio.cdn_url(storage[:], metadata.file_id)
	if !resolved {fmt.eprintln("CDN resolver did not return a usable URL"); return}
	fmt.println("CDN URL resolved.")
	return source, true
}

send_pong :: proc(socket: net.TCP_Socket, sender: ^ap.Packet_Cipher) {
	pong := ap.seal_packet(sender, 0x49, []u8{0, 0, 0, 0})
	if pong != nil {ap.send_full(socket, pong[:]); delete(pong)}
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
