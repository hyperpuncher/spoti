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
| emoji worker | system color font lookup, sequence shaping, and image rendering |
| playback and preload workers | authorization, audio resolution and decoding |
| Connect worker | Dealer connection, registration, incoming commands, state publication |
| AP keep-alive worker | idle connection maintenance |

network requests, cover decoding, and playback decoding stay off the UI
thread. each network worker owns its reusable curl handle. workers exchange
bounded messages with the UI rather than change UI-owned state directly.

library requests transfer ownership to the queue, including rejected sends.
each handled request moves into one owned result, which is sent on scope exit.
the result retains the request fields without duplicate strings. the receiver
adopts fields it needs, then frees the request with the remaining result data.
failed sends release the same owned result. partial worker startup uses the
normal shutdown path to close, drain, and release its queues.

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

artist opens also use one cached `queryArtistOverview` streaming request for
`visuals.headerImage`, `stats.monthlyListeners`, and Popular-track `playcount`.
the current query hash was verified with saved streaming approval. only valid
responses enter the cache; GraphQL errors can arrive with HTTP 200. a failed
query retains the native ARTIST_V4 fallback. there is no request per track.
playlist banners use the `header_image_url_desktop` format attribute from the
native playlist response already fetched for the page. banners fill the pane
width with a centered crop that keeps the image proportions. header height
is at most 35 percent of a small window and grows smoothly up to 40 percent
on larger windows. rounded top corners are applied after cropping. captions
use theme text colors over a smooth mask that reaches the page background
color at the lower edge. square cover art stays uncropped and is never used
as a wide banner. header size does not depend on image decoding or upload.
pages with unknown header metadata show a centered spinner, not a temporary
header. cached headers appear at once; artist opens also read the cached
overview without network access. only dedicated banner metadata selects a
wide header. pages without a banner keep their square cover.
banner captions reserve one metadata line, with owner and song totals joined
by `•`, so metadata arrival does not move the title. play counts are shown
only when supplied and when the pane has space for the numeric column.
hero titles keep the smaller-window size
and can grow to 96 on larger windows; the headline face uses Geist ExtraBold.

playlist tables show album and date-added columns when space is available.
header and row widths use the same calculation. album names link to their
album page; only the fitted text is clickable. date-added timestamps belong
to playlist occurrences, not track IDs: duplicate tracks can have different
dates. native reads use `ItemAttributes.timestamp` in Unix milliseconds;
Web API reads use `added_at` from `/playlists/{id}/items`. missing dates stay
blank, and filtering does not change the raw pagination offset.

native rootlist offsets count folder markers as well as playlists. keep the
native account on each page and request so those offsets never enter Web API
pagination. show folder contents in the flat grid without adding folder UI.

## playback and Connect

playback owns the queue. prefer Vorbis at 320, then 160, then 96 kbps.
Odin's `vendor:stb/vorbis` push API decodes the ranged, decrypted input.
retain one 64 KiB decrypted range and one 64 KiB decoder input buffer,
regardless of track length. headers or packets that exceed the input limit
fail instead of growing the buffer. decoded PCM stays in the decoder's frame
and the bounded playback queue; mono output is copied to both stereo channels.

stb's CRC-checked page scanner reads the final sample position from the file
tail. seeking uses one byte estimate, then binary search when needed. decode
through the first page after resynchronization to restore its exact sample
position before returning audio. skip decoded samples before the requested
position. cancellation and read errors stop the worker; they are not clean EOF.

keep the previous title and artist together until the playback metadata is
ready, then update both before publishing the MPRIS metadata snapshot.
AP requests share one serialized connection and cipher state. Connect and
AP use the same persistent device identity. library workers read the AP country
code as an atomic two-letter copy, not a view into connection memory.

the last-played record stores the queue, its current index, shuffle order,
and playback source. restore moves the loaded queue into playback without
starting audio. saves borrow the live queue only while encoding; there is no
second owned queue snapshot. the last browsed collection is separate.
rows that arrive later extend the restored queue when its source page is open;
playback near the queue's end also requests more rows from that page.
when the last track finishes without repeat, stop and select the first queued
track at 0:00. Next from the last track does the same without starting audio.
queue items retain titles and durations so the stopped footer needs no network
request. automatic repeat-track and repeat-context transitions keep playing.

manual additions keep a queue-origin flag and stable ordinals. insert them
after the current track and pending manual additions. shuffle keeps those
pending additions in order. collection pagination counts only collection rows,
not manual additions, so later pages do not skip tracks. saved queues retain
the origin flag; restore rebuilds the collection-row count. a release queued
from What's New loads under the feed, finishes all album pages, then inserts
one FIFO run. queue and search tracks use the same add-to-playlist picker.

Dealer requests become UI events. reply only after the UI accepts a command;
reject unsupported commands. publish actual local playback state. send state
changes at once and position-only changes every five seconds. stop local
audio when another device takes playback.

footer controls target the remote device while remote control is active.
an explicit local track choice returns control to local playback. device
transfer completion is handled before the playback stage.

## rendering and caching

steady playback redraws at up to 30 fps. input events wake the loop at once;
scrolling, dragging, and UI animations use the display rate. paused views do
not redraw continuously when no other work needs a frame.

icon tint variants share one texture per icon. image commands borrow their
tint from the UI-owned palette. rounded masks not used in the current frame
are released after presentation. cover textures use a soft 128 MiB RGBA budget;
old unused covers are evicted after presentation and can load again from disk.
visible images and the displayed and requested player covers stay protected,
even when they exceed the budget. icons and fades do not use the cover budget.

virtualize grids and track rows with full-height spacers. Clay can cull draw
commands but still processes layout, and only supports 100 clip containers.
keep offscreen rows out of layout and clip pointer hits to their visible area.
card and track text is shortened to fit before layout. grids and track tables
own clipping instead of allocating clip containers per card or track row. image decoding accepts dimensions up
to 4096 pixels so Spotify's 2660-pixel artist headers can be displayed.
numeric fields use the monospace face; titles use proportional faces.
square cover artwork is not cropped or otherwise materially changed;
dedicated banners may be cropped to fit their bounded header.

ordinary text uses Geist with character-based system outline fallbacks.
each primary and fallback font pair is attached once; SDL_ttf appends duplicate
entries otherwise. emoji uses whole grapheme clusters with stable inline cells.
a worker owns the color font and renders cached images; SDL texture uploads and
scaled drawing stay on the UI thread. image arrivals wake the event loop and
never change text measurements. see [font behavior and limits](../assets/fonts/FONTS.md).

hero titles and metadata are cached by detail revision, row count, size and
viewport width. page growth or header changes invalidate only the matching
entry; steady frames reuse the fitted label and summary.

cached content appears before background revalidation. if a detail request
fails, keep the available card preview, header, and rows. show the error below
the header controls instead of replacing the page. rate limits keep the same
retry delay. successful playlist removal updates the existing rows only after
the server confirms it.

the shared Web API retry deadline is atomic in memory and saved in `state.json`.
restore it before workers start. save a changed deadline in the normal frame
state save and after the library worker stops, since an in-flight request can
finish during shutdown. a new response cannot shorten an existing deadline.
HTTP 429 diagnostics recognise only `QUOTA_EXCEEDED`; other reasons are logged
as unknown. response bodies and server message text are never logged.

startup replaces the warm library snapshot without forcing fresh Web API
requests. native rootlist still revalidates. cache only the account ID needed
for playlist ownership, not the full profile. confirmed membership writes
invalidate the first cached Web API index page for that collection type.
a successful new browser approval clears API response caches before the worker
handles requests, since the grant can belong to another account. saved-grant
refreshes keep the cache. artwork, audio, local history, and retry deadlines
are not cleared by approval.

API responses are fresh for five minutes; library pages for six hours.
stale responses can cover network failures for up to 30 days. library cache
directories are created once at launch; read paths do not create directories.
the audio cache holds encrypted audio only, with a 4 GiB limit. audio keys and
signed audio URLs stay in memory. persistent application state uses `state.json`
without legacy format readers. volume changes update audio at once but the
state file is written once when the drag ends.

## diagnostics and portability

logs contain endpoint shapes, status codes, timings, counts, and state flags.
never log credentials, tokens, account or device IDs, signed audio URLs,
connection keys, command bodies, or response bodies.

use OS-specific files for platform boundaries. credentials use Secret Service,
Keychain Services, or Credential Manager directly. refresh tokens never enter
subprocess arguments. backend changes keep the existing service and slot names.
MPRIS is Linux-only. type checking another target is not a substitute for
building and running on that platform.
