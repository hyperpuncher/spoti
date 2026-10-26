# spoti agent notes

## workflow

- run `just fmt`, `just check`, and `just test` after code changes
- keep the README short; put setup, architecture, and decisions in tracked `docs/` files
- check Odin core/vendor packages before adding native bindings
- never open UI probes or manipulate the desktop without permission
- native Wayland only, with direct SDL3 and Clay
- use arenas from `core:mem/virtual` for grouped library response lifetimes
- after moving an arena-owning struct, rebind its dynamic arrays' `.allocator` to the destination arena before resizing
- keep network, cover decoding, and playback work off the UI thread
- Connect and AP must use the same persistent device identity
- acknowledge Connect requests only after the UI accepts them; reject unknown commands
- never log Dealer addresses, connection keys, device IDs or command bodies
- do not log credentials, tokens, redirect URLs, audio keys, or signed CDN URLs
- keep UI icons as optimized white SVGs; do not add generated PNG copies

## local references

- Odin language: `~/docs/odin-lang.org/content/docs/{overview,faq,demo,testing}.md`
- Odin core APIs and examples: `~/docs/Odin/core/`, `~/docs/odin-examples/`
- Clay overview and API: `~/docs/clay/README.md`
- Clay Odin binding: `~/docs/clay/bindings/odin/`
- Clay SDL3 renderer reference: `~/docs/clay/renderers/SDL3/clay_renderer_SDL3.c`
- SDL3 API: `~/docs/sdlwiki/SDL3/`
- SDL_ttf: `~/docs/SDL_ttf/`
- SDL_image: `~/docs/SDL_image/`
- Spotify Web API schema: `~/docs/spotify-web-api/open-api-schema.yaml`
- Spotify policy: `~/docs/spotify-web-api/policies.yaml`
- librespot protocol and playback reference: `~/docs/librespot/`
- Spotifast behavior reference: `~/projects/spotifast/`
- Lucide sources: `~/docs/lucide/`

## product rules

- use the official OpenAPI schema as endpoint authority
- before adding or changing an endpoint, read its whole path block: list every method, read each `operationId`, and reject anything marked `deprecated: true`; prefer `/playlists/{id}/items` over the deprecated `/playlists/{id}/tracks`, and `/me/library` over the deprecated `/me/tracks`, `/me/albums`, `/me/episodes` and `/me/shows` writes and contains checks
- supported Vorbis preference is 320, then 160, then 96 kbps
- library grids use 2 to 4 columns and load more automatically near the bottom
- virtualize library cards, discography, and track rows with full-height spacers; Clay culls drawing, not layout, and tracks only 100 clip containers
- numeric fields use the monospace face; titles use proportional faces
- square cover artwork must not be cropped or otherwise materially altered; dedicated artist and playlist banners may use a centered crop to fill a height-limited header
