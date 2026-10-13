# architecture and decisions

spoti is a native Odin application. SDL3 provides windows, events, rendering,
and audio output. Clay provides layout. Linux uses native Wayland; macOS and
Windows use SDL's platform support. there is no Rust helper or librespot
runtime dependency. librespot and Spotifast are protocol references.

## thread boundaries

| component | responsibility |
| --- | --- |
| UI thread | events, navigation, layout, texture upload, playback decisions |
| library worker | account data, native playlist reads, search, confirmed writes |
| cover worker | artwork requests and image decoding |
| playback and preload workers | authorization, audio resolution and decoding |
| Connect worker | Dealer connection, registration, incoming commands, state publication |
| AP keep-alive worker | idle connection maintenance |

network requests, cover decoding, and playback decoding stay off the UI
thread. each network worker owns its reusable curl handle. workers exchange
bounded messages with the UI rather than change UI-owned state directly.

`main.odin` keeps an owned `App` and a short-lived `Frame`. its frame stages
handle events, navigation, library results, playback, scrolling, layout,
artwork, commands, and persistence. stage order matters: a playback transfer
must stop local audio before the playback stage, not during layout.

## ownership

library pages and details each own a `core:mem/virtual` arena. strings,
rows, and cards that share a response lifetime use that arena. destroying
the arena releases the response in one operation.

moving an arena-owning value does not update allocator pointers inside its
dynamic arrays. rebind those arrays to the destination arena before resizing.
copy strings into a new owner when a queue, navigation entry, or worker
message must outlive its source page. temporary wire views do not leave
the request scope.

use explicit `defer` cleanup. an account name obtained for the first native
playlist page stays alive through the complete request. later requests own
their account string; the reader only borrows it.

## Spotify data sources

Web API and streaming approval are separate. use the official OpenAPI schema
for public endpoints and reject deprecated operations.

with saved streaming approval, the playlist index uses the native decorated
rootlist. playlist headers and track metadata use the same session. the
personal Web API omits some Spotify-made playlists, so it is only the index
fallback when the native read is unavailable. albums, artists, and saved
songs retain their Web API reads.

native rootlist offsets count folder markers as well as playlists. keep the
native account on each page and request so those offsets never enter Web API
pagination. show folder contents in the flat grid without adding folder UI.

## playback and Connect

playback owns the queue. prefer Vorbis at 320, then 160, then 96 kbps.
AP requests share one serialized connection and cipher state. Connect and
AP use the same persistent device identity.

Dealer requests become UI events. reply only after the UI accepts a command;
reject unsupported commands. publish actual local playback state. send state
changes at once and position-only changes every five seconds. stop local
audio when another device takes playback.

footer controls target the remote device while remote control is active.
an explicit local track choice returns control to local playback. device
transfer completion is handled before the playback stage.

## rendering and caching

virtualize grids and track rows with full-height spacers. Clay can cull draw
commands but still processes layout, and only supports 100 clip containers.
keep offscreen rows out of layout and clip pointer hits to their visible area.
numeric fields use the monospace face; titles use proportional faces.
artwork is not cropped or otherwise materially changed.

cached content appears before background revalidation. successful playlist
removal updates the existing rows only after the server confirms it.

API responses are fresh for five minutes; library pages for six hours.
stale responses can cover network failures for up to 30 days. the audio cache
holds encrypted audio only, with a 4 GiB limit. audio keys and signed audio
URLs stay in memory. persistent application state uses `state.json` without
legacy format readers.

## diagnostics and portability

logs contain endpoint shapes, status codes, timings, counts, and state flags.
never log credentials, tokens, account or device IDs, signed audio URLs,
connection keys, command bodies, or response bodies.

use OS-specific files for platform boundaries. credentials use the native
credential store. MPRIS is Linux-only. type checking another target is not a
substitute for building and running on that platform.
