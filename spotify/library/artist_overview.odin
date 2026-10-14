// Artist banners, listeners and Popular rows from one verified streaming query.
// The native ARTIST_V4 reader remains the fallback if this private query changes.
package library

import http "../http"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

ARTIST_OVERVIEW_HASH :: "35648a112beb1794e39ab931365f6ae4a8d45e65396d641eeda94e4003d41497"

Artist_Overview_Track :: struct {
	uri, name:   string,
	play_count:  string `json:"playcount"`,
	duration:    struct {
		milliseconds: int `json:"totalMilliseconds"`,
	},
	playability: struct {
		playable: bool,
	},
	artists:     struct {
		items: []struct {
			uri:     string,
			profile: struct {
				name: string,
			},
		},
	},
	album:       struct {
		uri:    string,
		covers: struct {
			sources: []Image,
		} `json:"coverArt"`,
	} `json:"albumOfTrack"`,
}

parse_artist_overview :: proc(body: []u8, detail: ^Detail) -> bool {
	response: struct {
		errors: []json.Value,
		data:   struct {
			artist: struct {
				uri:         string,
				profile:     struct {
					name: string,
				},
				visuals:     struct {
					header: struct {
						sources: []Image,
					} `json:"headerImage"`,
				},
				stats:       struct {
					listeners: i64 `json:"monthlyListeners"`,
				},
				discography: struct {
					top: struct {
						items: []struct {
							track: Artist_Overview_Track,
						},
					} `json:"topTracks"`,
				},
			} `json:"artistUnion"`,
		},
	}
	if json.unmarshal(body, &response, allocator = context.temp_allocator) != nil ||
	   len(response.errors) > 0 {return false}
	artist := response.data.artist
	if artist.uri !=
		   fmt.aprintf("spotify:artist:%s", detail.id, allocator = context.temp_allocator) ||
	   artist.profile.name == "" ||
	   len(artist.discography.top.items) > TOP_TRACKS_MAX {return false}
	allocator := virtual.arena_allocator(&detail.arena)
	rows := make([dynamic]Track_Row, 0, len(artist.discography.top.items), allocator)
	for item in artist.discography.top.items {
		track := item.track
		if !track.playability.playable {continue}
		if _, valid := playlist_track_id(track.uri); !valid {continue}
		artists := make([]Artist, len(track.artists.items), context.temp_allocator)
		for a, i in track.artists.items {artists[i] = Artist {
				name = a.profile.name,
				uri  = a.uri,
			}}
		row, valid := track_row(
			Track_Ref {
				uri = track.uri,
				name = track.name,
				duration_ms = track.duration.milliseconds,
				artists = artists,
				album = Album_Ref{uri = track.album.uri, images = track.album.covers.sources},
			},
			allocator,
		)
		if !valid {continue}
		if count, parsed := strconv.parse_i64(track.play_count);
		   parsed && count > 0 {row.play_count = count}
		append(&rows, row)
	}
	detail.banner = strings.clone(cover_url(artist.visuals.header.sources, .Largest), allocator)
	detail.monthly_listeners = max(0, artist.stats.listeners)
	detail.rows = rows
	return true
}

fetch_artist_overview :: proc(
	access: string,
	detail: ^Detail,
	country: string,
	reuse: rawptr,
	cancel: ^bool,
) -> bool {
	key := fmt.aprintf(
		"artist-overview:%s:%s:%s",
		ARTIST_OVERVIEW_HASH,
		detail.id,
		country,
		allocator = context.temp_allocator,
	)
	if cached, hit := cache_read("api", key, PAGE_TTL); hit {
		defer delete(cached)
		if parse_artist_overview(cached[:], detail) {return true}
	}
	request: struct {
		operation_name: string `json:"operationName"`,
		variables:      struct {
			uri, locale: string,
			prerelease:  bool `json:"includePrerelease"`,
		},
		extensions:     struct {
			query: struct {
				version: int,
				hash:    string `json:"sha256Hash"`,
			} `json:"persistedQuery"`,
		},
	}
	request.operation_name = "queryArtistOverview"
	request.variables.uri = fmt.aprintf(
		"spotify:artist:%s",
		detail.id,
		allocator = context.temp_allocator,
	)
	request.extensions.query = {
		version = 1,
		hash    = ARTIST_OVERVIEW_HASH,
	}
	encoded, err := json.marshal(request, allocator = context.temp_allocator)
	if err != nil {return false}
	body, status, fetched := http.post_json(
		RELEASE_FEED_ADDRESS,
		string(encoded),
		{bearer = access, limit = ARTIST_METADATA_LIMIT, cancel = cancel},
		reuse,
	)
	defer delete(body)
	if fetched && status == 200 && parse_artist_overview(body[:], detail) {
		cache_write("api", key, body[:])
		return true
	}
	if cached, hit := cache_read("api", key, API_STALE); hit {
		defer delete(cached)
		return parse_artist_overview(cached[:], detail)
	}
	return false
}
