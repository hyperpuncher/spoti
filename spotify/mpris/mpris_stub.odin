#+build !linux
// Other platforms install no-op stubs until their native media APIs land
// (MPNowPlayingInfoCenter on macOS, SMTC on Windows).
package mpris

start :: proc(wake: Wake) -> bool {return false}

poll :: proc() -> (command: Command, position_ms: int, ok: bool) {return}

update :: proc(now: Now_Playing) {}

seeked :: proc(position_ms: int) {}

close :: proc() {}
