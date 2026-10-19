# Spotify setup and limits

spoti requires Spotify Premium for local playback.

## separate approvals

- the personal Web API app handles account reads and supported writes.
  on first launch spoti shows a setup screen: create an app in the
  Spotify dashboard, add `http://127.0.0.1:8989/login` as a redirect URI,
  then paste the 32-character client ID. spoti stores it in the operating
  system's credential store beside the sign-in grants. `WEB_CLIENT_ID`
  remains as an override for headless and development use.
- streaming approval handles native playback, Connect, and session reads.
  play a track locally to approve streaming on a new installation.

refresh grants are stored in the operating system's credential store.
on macOS, allow spoti to access its Keychain entries if the system asks.
background native reads reuse saved streaming approval and never start a
browser approval window. Connect and library startup wait for an existing
grant operation rather than treat a busy grant as unavailable.

## Web API quotas

provide a client ID, not an access token. for personal use, each user creates
an app under their own Spotify developer account and signs in through Spotify.
spoti obtains that user's tokens; users must not share sign-in grants.

a public app can use one client ID with separate tokens for each user, but
public use needs Spotify's extended-quota approval. the personal setup is not
a substitute for that approval. see [quota modes and eligibility](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

Spotify has short-term rate limits and separate development-mode quotas.
endpoints share quota groups. since July 23, 2026, apps under the same developer
account also share quota. a new token or another client ID under that account
does not reset it. see [Spotify's quota update](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates).

fresh library pages are reused for six hours. the profile cache stores only the
account ID, not the full response. a successful library save or removal clears
the affected first index page so the next load gets the confirmed state.
a successful new browser approval clears API response caches so another
account cannot reuse the old account ID or library pages. artwork, audio,
local history, and retry deadlines are kept. refreshing a saved grant keeps
the response cache.
Web API retry deadlines are saved across restarts. a long wait can still occur
when Spotify's quota is exhausted; cached content remains available.

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

## queue

select the queue icon beside the device button to open the playback queue.
the panel shows the current track and upcoming tracks, with the titles,
artists, and durations already held in memory. select a track to play it.
closing the panel does not change playback or queue order. right-click a track
in a track list, search results, or the queue and select **Add to queue**. added
tracks play in order after existing manual additions, before the remaining
collection tracks. adding a track does not interrupt playback; duplicates are
kept.

long queues use a bounded visible list. opening the panel sends no Spotify
requests and does not download artwork. in narrow windows, the queue uses the
detail pane until closed. reordering and removal are not supported yet.

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
