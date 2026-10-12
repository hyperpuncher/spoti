# spoti agent notes

## workflow

- run `just fmt`, `just check`, and `just test` after code changes
- read the relevant doc or schema in full before writing code; never grep for one operation name and take the first match
- never open UI probes or manipulate the desktop without permission
- native Wayland only, with direct SDL3 and Clay
- use arenas from `core:mem/virtual` for grouped library response lifetimes
- after moving an arena-owning struct, rebind its dynamic arrays' `.allocator` to the destination arena before resizing
- keep network, cover decoding, and playback work off the UI thread
- Connect and AP must use the same persistent device identity
- acknowledge Connect requests only after the UI accepts them; reject unknown commands
- never log Dealer addresses, connection keys, device IDs or command bodies
- do not log credentials, tokens, redirect URLs, audio keys, or signed CDN URLs
- retain only Lucide SVG sources in `assets/icons/`; `scripts/build-icons.sh` generates ignored PNGs

## local references

- Odin language: `~/docs/odin-lang.org/content/docs/{overview,faq,demo,testing}.md`
- Odin core APIs and examples: `~/docs/Odin/core/`, `~/docs/odin-examples/`
- Clay overview and API: `~/docs/clay/README.md`
- Clay Odin binding: `~/docs/clay/bindings/odin/`
- Clay SDL3 renderer reference: `~/docs/clay/renderers/SDL3/clay_renderer_SDL3.c`
- SDL3 API: `~/docs/sdlwiki/SDL3/`
- SDL_ttf: `~/docs/SDL_ttf/`
- Spotify Web API schema: `~/docs/spotify-web-api/open-api-schema.yaml`
- Spotify policy: `~/docs/spotify-web-api/policies.yaml`
- librespot protocol and playback reference: `~/docs/librespot/`
- Spotifast behavior reference: `~/projects/spotifast/`
- Lucide sources: `~/docs/lucide/`

## implementation map

- `main.odin`: SDL event loop, input, playback transitions, texture upload
- `layout.odin`: toolbar, player bar, root layout and theme
- `library_view.odin`: virtualized library grids, detail pages and track rows
- `renderer.odin`: Clay text measurement, SDL render commands and image elements
- `playback.odin`: owned play queue and login/decode worker
- `connect.odin`: UI-thread playback snapshots for the Connect worker
- `spotify/connect/`: native Dealer worker, Connect state encoding and incoming commands
- `diagnostic/`: privacy-safe crash breadcrumbs in `~/.local/state/spoti/spoti.log`
- `ui/sdl.odin`: Wayland SDL setup and rendering
- `ui/font.odin`: fontconfig and per-size SDL_ttf cache
- `spotify/library/`: Web API auth, pagination, detail pages, cache, cover worker
- `spotify/player/stream.odin`: bounded decode worker
- `spotify/session/connection.odin`: shared AP connection, serialized requests, idle ping handling and reconnect
- `ui/text.odin`: SDL_ttf text pool bounded by the visible frame
- `spotify/ap/`, `spotify/audio/`, `spotify/track/`: Spotify protocol and streaming

## product rules

- use the official OpenAPI schema as endpoint authority
- before adding or changing an endpoint, read its whole path block: list every method, read each `operationId`, and reject anything marked `deprecated: true`; prefer `/playlists/{id}/items` over the deprecated `/playlists/{id}/tracks`, and `/me/library` over the deprecated `/me/tracks`, `/me/albums`, `/me/episodes` and `/me/shows` writes and contains checks
- supported Vorbis preference is 320, then 160, then 96 kbps
- library grids use 2 to 4 columns and load more automatically near the bottom
- virtualize library cards, discography, and track rows with full-height spacers; Clay culls drawing, not layout, and tracks only 100 clip containers
- numeric fields use the monospace face; titles use proportional faces
- artwork must not be cropped or otherwise materially altered
