# Spotify setup and limits

spoti requires Spotify Premium for local playback.

## separate approvals

- the personal Web API app handles account reads and supported writes.
  configure its public client ID with `WEB_CLIENT_ID`.
- streaming approval handles native playback, Connect, and session reads.
  play a track locally to approve streaming on a new installation.

refresh grants are stored in the operating system's credential store.
background native reads reuse saved streaming approval and never start a
browser approval window. Connect and library startup wait for an existing
grant operation rather than treat a busy grant as unavailable.

## playlist coverage

with saved streaming approval, the playlist list uses Spotify's native
rootlist. this includes saved Spotify-made playlists such as Release Radar.
playlist titles, covers, and songs also use the session. folders contribute
their playlists to the flat grid, but folder rows are not shown.

without streaming approval, spoti uses the personal Web API. Spotify filters
algorithmic and Spotify-owned editorial playlists for newer development
apps, so that list can be incomplete. after first approving streaming,
restart spoti to load the native list. albums, artists, and saved songs
continue to use the Web API.

see [Spotify's API access changes](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api).

pins are local to spoti. Spotify's own pins are not synced, so a playlist
pinned in the official app can appear farther down spoti's list.

## what's new

select the bell beside search to see recent music from followed artists.
large square covers have the title, artists, relative release time, play,
and save controls beside them. play keeps the feed open. select the cover
or text to open the album. time labels such as "8 hours ago" use Spotify's
catalog release timestamp, not the time it added an item to the feed.
right-click a release to play it, save or remove it from the library, add
all of its tracks to a playlist, copy its link, or open it in Spotify.

the view reads Spotify's internal music-only `queryWhatsNewFeed` route.
it reuses saved streaming approval without a browser prompt. there is no
artist scan or public Web API fallback. the view shows catalog release
dates within the last seven days, removes duplicate album IDs, and sorts
newest first. podcasts are excluded.

the worker reads 50 feed items per page.
validated responses are cached per account for six hours and persist across
restarts. closing the view stops further page requests. a rate limit stops
loading until the user reopens the view after Spotify's wait period.

this is an internal route. Spotify can replace its persisted-query hash.
a rejected query remains a visible error rather than starting an artist
scan. saving and opening albums still use the existing library operations.

## Connect

spoti registers as a computer named `spoti` on the streaming account.
another Spotify client can transfer playback to it and send playback and
volume commands. spoti reports local state and stops local audio when another
device takes playback. the device picker also controls other signed-in devices.

Dealer payloads can be plain or gzip-compressed after base64 decoding.
state updates include shuffle, repeat, and a queue window of at most 80
tracks, with its current index and revision. remote queue editing remains
unsupported.

current limits:

- no local Zeroconf discovery or pairing;
- no remote queue editing or complete transferred-context pagination;
- a transferred queue contains at most 80 tracks;
- episodes are not supported;
- remote state polling is not a complete remote queue or metadata mirror.

## verification

live backend checks confirmed registration, the connection heartbeat, and
native library coverage. the actual library request and page merge returned
116 playlists for the tested account, including Release Radar. its header,
cover, and first, middle, and final track windows were also checked.
phone-to-spoti audio transfer was confirmed in a live user test. user tests
also confirmed remote playback controls and the phone's shuffle indicator.

these checks do not guarantee access to every Spotify resource. report a
server refusal rather than show an unsupported operation as successful.
