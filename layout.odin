package main

import library "spotify/library"
import oauth "spotify/oauth"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

// Active palette. Variables, not constants, so the app can follow the
// system theme without touching every use site; apply_theme assigns them
// all at once on startup and on SDL_EVENT_SYSTEM_THEME_CHANGED.
BG := DARK_THEME.bg
SIDEBAR := DARK_THEME.sidebar
PANEL := DARK_THEME.panel
CARD := DARK_THEME.card
HOVER := DARK_THEME.hover
SELECTED := DARK_THEME.selected
PLAYER := DARK_THEME.player
WHITE := DARK_THEME.text
FOOTER_HOVER := DARK_THEME.footer_hover
HERO_HOVER := DARK_THEME.hero_hover
MUTED := DARK_THEME.muted
GREEN := DARK_THEME.green

Theme :: struct {
	bg:           clay.Color,
	sidebar:      clay.Color,
	panel:        clay.Color,
	card:         clay.Color,
	hover:        clay.Color,
	selected:     clay.Color,
	player:       clay.Color,
	text:         clay.Color,
	footer_hover: clay.Color,
	hero_hover:   clay.Color,
	muted:        clay.Color,
	green:        clay.Color,
}

DARK_THEME :: Theme {
	bg           = {18, 18, 18, 255},
	sidebar      = {24, 24, 24, 255},
	panel        = {32, 32, 32, 255},
	card         = {45, 45, 45, 255},
	hover        = {52, 52, 52, 255},
	selected     = {36, 36, 36, 255},
	player       = {12, 12, 12, 255},
	text         = {245, 245, 245, 255},
	footer_hover = {225, 225, 225, 255},
	hero_hover   = {38, 224, 106, 255},
	muted        = {165, 165, 165, 255},
	green        = {30, 215, 96, 255},
}

LIGHT_THEME :: Theme {
	bg           = {255, 255, 255, 255},
	sidebar      = {242, 242, 242, 255},
	panel        = {233, 233, 233, 255},
	card         = {229, 229, 229, 255},
	hover        = {214, 214, 214, 255},
	selected     = {226, 226, 226, 255},
	player       = {247, 247, 247, 255},
	text         = {28, 28, 28, 255},
	footer_hover = {70, 70, 70, 255},
	hero_hover   = {38, 224, 106, 255},
	muted        = {112, 112, 112, 255},
	green        = {30, 215, 96, 255},
}

apply_theme :: proc(dark: bool) {
	theme := dark ? DARK_THEME : LIGHT_THEME
	BG = theme.bg
	SIDEBAR = theme.sidebar
	PANEL = theme.panel
	CARD = theme.card
	HOVER = theme.hover
	SELECTED = theme.selected
	PLAYER = theme.player
	WHITE = theme.text
	FOOTER_HOVER = theme.footer_hover
	HERO_HOVER = theme.hero_hover
	MUTED = theme.muted
	GREEN = theme.green
}

SIDEBAR_MIN :: 320
SIDEBAR_MAX :: 640
// The player seek bar stays a comfortable length on very wide windows.
SEEK_MAX_WIDTH :: 620

LIBRARY_TABS :: [3]library.Kind{.Playlists, .Albums, .Artists}
LIBRARY_TAB_LABELS :: [3]string{"Playlists", "Albums", "Artists"}
SEARCH_TABS :: [4]library.Kind{.Playlists, .Albums, .Artists, .Tracks}
SEARCH_TAB_LABELS :: [4]string{"Playlists", "Albums", "Artists", "Tracks"}

View :: struct {
	title:          string,
	status:         string,
	button:         string,
	progress:       f32,
	elapsed:        string,
	total:          string,
	input:          string,
	cover:          string,
	repeat:         bool,
	shuffle:        bool,
	volume:         f32,
	input_active:   bool,
	select_all:     bool, // the whole query is selected
	setup_error:    string, // borrowed; setup screen error line
	album_linked:   bool, // footer title opens the playing album
	artist_linked:  bool, // footer artist opens the playing artist
	pinned:         bool,
	sign_in:        bool, // a library browser approval is waiting for a click
	can_back:       bool,
	can_forward:    bool,
	search_mode:    bool,
	releases:       bool,
	search_kind:    library.Kind,
	menu_open:      bool,
	menu_x:         f32,
	menu_y:         f32,
	menu_count:     int,
	menu_labels:    [MENU_ITEMS_MAX]string,
	menu_selected:  int,
	menu_add_index: int, // row index of Add to playlist, or -1
	picker_open:    bool,
	picker_rows:    []library.Entry,
	device_open:    bool, // the Connect device panel is showing
	device_active:  bool, // a Connect device is the API-active one
	device_rows:    []library.Device, // borrowed; the last fetched list
	device_loading: bool,
	device_error:   bool,
	drag_active:    bool, // a track is being dragged onto a playlist card
	drag_x:         f32,
	drag_y:         f32,
	drag_label:     string,
	drop_target:    int, // playlist card index under the drag, or -1
	toast:          string, // transient add-to-playlist feedback
	scroll_active:  bool, // middle-click autoscroll anchor indicator
	current_uri:    string, // borrowed selected track; matches a row uri while it owns playback
	playing:        bool, // audio flowing this frame; freezes the row bars when false
	scroll_x:       f32,
	scroll_y:       f32,
}

chip :: proc(label: string, id: u32, active: bool, d: f32) {
	if clay.UI_WithId(clay.ID("chip", id))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(32 * d)},
			padding = clay.PaddingAll(u16(14 * d)),
			childAlignment = {y = .Center},
		},
		backgroundColor = active ? WHITE : clay.PointerOver(clay.ID("chip", id)) ? HOVER : CARD,
		cornerRadius = clay.CornerRadiusAll(16 * d),
	},
	) {
		clay.Text(label, clay.TextElementConfig{fontSize = 14, textColor = active ? BG : WHITE})
	}
}

// Snappy press feedback for fixed-size buttons. The icon shrinks instantly
// while held and springs back over a fast ease-out on release; the outer
// hitbox never moves, so siblings never shift. Hover only tints, and
// keyboard activation never animates.
BUTTON_PRESS :: 0.95
BUTTON_SPRING_MS :: 70.0

Button_Fx :: struct {
	held:     bool, // pressed last frame; a clean release stamps released
	released: u64, // ticksns of release; 0 at rest
}

Button_Fx_Ctx :: struct {
	anims:      ^map[string]Button_Fx,
	mouse_down: bool,
	animating:  bool, // a spring is mid-flight; main keeps frames coming
}

// Icon scale for a button id plus its hover state. Disabled buttons skip
// the map entirely and only report hover for the cursor.
button_fx :: proc(
	ctx: ^Button_Fx_Ctx,
	id: string,
	enabled: bool = true,
) -> (
	scale: f32,
	hovered: bool,
) {
	scale = 1
	hovered = clay.PointerOver(clay.ID(id))
	if !enabled {return scale, false}
	fx := ctx.anims[id]
	if hovered && ctx.mouse_down {
		fx.held = true
		scale = BUTTON_PRESS
	} else {
		if fx.held {
			fx.held = false
			fx.released = sdl.GetTicksNS()
		}
		if fx.released != 0 {
			t := f32(sdl.GetTicksNS() - fx.released) / 1e9 * 1000 / BUTTON_SPRING_MS
			if t >= 1 {
				fx.released = 0
			} else {
				k := 1 - (1 - t) * (1 - t) * (1 - t)
				scale = BUTTON_PRESS + (1 - BUTTON_PRESS) * k
				ctx.animating = true
			}
		}
	}
	ctx.anims[id] = fx
	return scale, hovered
}

top_bar :: proc(view: View, textures: ^Textures, fx: ^Button_Fx_Ctx, d: f32) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(58 * d)},
			padding = {left = u16(10 * d), right = u16(10 * d)},
			childAlignment = {x = .Center, y = .Center},
			childGap = u16(4 * d),
		},
		backgroundColor = BG,
	},
	) {
		icon_button(
			"toolbar_back",
			"chevron-left",
			view.can_back ? .Muted : .Disabled,
			textures,
			fx,
			d,
			icon_size = 20,
			target_size = 40,
		)
		icon_button(
			"toolbar_forward",
			"chevron-right",
			view.can_forward ? .Muted : .Disabled,
			textures,
			fx,
			d,
			icon_size = 20,
			target_size = 40,
		)
		if clay.UI_WithId(clay.ID("track_input"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(440 * d), height = clay.SizingFixed(40 * d)},
				padding = {left = u16(14 * d), right = u16(14 * d)},
				childAlignment = {y = .Center},
			},
			backgroundColor = view.input_active ? CARD : PANEL,
			cornerRadius = clay.CornerRadiusAll(20 * d),
		},
		) {
			// A selected query hugs a highlight box sized to the text, so
			// the normal path keeps its exact layout; the cap matches the
			// pill content width.
			if clay.UI()(
			{
				layout = {sizing = {width = clay.SizingFit({max = 412 * d})}},
				backgroundColor = view.select_all ? SELECTED : clay.Color{},
				cornerRadius = clay.CornerRadiusAll(6 * d),
			},
			) {
				clay.Text(
					view.input,
					clay.TextElementConfig {
						fontSize = 14,
						textColor = view.input_active ? WHITE : MUTED,
						wrapMode = .None,
					},
				)
			}
		}
		icon_button(
			"toolbar_releases",
			"bell",
			view.releases ? .Green : .Muted,
			textures,
			fx,
			d,
			icon_size = 20,
			target_size = 40,
		)
	}
}

// Toolbar, hero and player icons share a background-free target. Hover
// brightens muted icons and gives primary icons the play button's hover
// tone. Active and disabled colors retain their meaning.
icon_button :: proc(
	id, icon: string,
	tint: Icon_Tint,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	d: f32,
	icon_size: f32 = 21,
	target_size: f32 = 32,
) {
	scale, hovered := button_fx(fx, id, tint != .Disabled)
	active := tint
	if hovered {
		#partial switch tint {
		case .Muted:
			active = .White
		case .White:
			active = .Hover
		}
	}
	size := icon_size * d * scale
	if clay.UI_WithId(clay.ID(id))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(target_size * d),
				height = clay.SizingFixed(target_size * d),
			},
			childAlignment = {x = .Center, y = .Center},
		},
	},
	) {
		icon_element(textures, icon, active, size)
	}
}

round_play_button :: proc(
	id, icon: string,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	d, size, icon_size: f32,
	background, hover: clay.Color,
	enabled := true,
) {
	scale, over := button_fx(fx, id, enabled)
	if clay.UI_WithId(clay.ID(id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(size * d), height = clay.SizingFixed(size * d)},
			childAlignment = {x = .Center, y = .Center},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(size * d * scale),
					height = clay.SizingFixed(size * d * scale),
				},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = !enabled ? CARD : over ? hover : background,
			cornerRadius = clay.CornerRadiusAll(size * d * scale / 2),
		},
		) {
			icon_element(textures, icon, enabled ? .Dark : .Disabled, icon_size * d * scale)
		}
	}
}

player_bar :: proc(view: View, textures: ^Textures, fx: ^Button_Fx_Ctx, d: f32) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(92 * d)},
			padding = clay.PaddingAll(u16(14 * d)),
			childGap = u16(20 * d),
			childAlignment = {y = .Center},
		},
		backgroundColor = PLAYER,
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(320 * d), height = clay.SizingGrow({})},
				childGap = u16(12 * d),
				childAlignment = {y = .Center},
			},
		},
		) {
			// The slot stays reserved so the title never shifts when art loads.
			if len(view.cover) > 0 {
				cover_element(textures, view.cover, 64 * d, 7 * d)
			} else if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(64 * d), height = clay.SizingFixed(64 * d)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = CARD,
				cornerRadius = clay.CornerRadiusAll(7 * d),
			},
			) {
				icon_element(textures, "music", .Muted, 24 * d)
			}
			if clay.UI()(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow({})},
					childGap = u16(3 * d),
				},
				clip = {horizontal = true},
			},
			) {
				// Hug boxes so exactly the text is clickable. The title is
				// already white; the pointer alone marks it, while the
				// artist brightens like every other quiet icon.
				if clay.UI_WithId(clay.ID("footer_title"))(
				{layout = {sizing = {width = clay.SizingFit({})}}},
				) {
					clay.Text(
						view.title,
						clay.TextElementConfig{fontSize = 15, textColor = WHITE, wrapMode = .None},
					)
				}
				artist_over := view.artist_linked && clay.PointerOver(clay.ID("footer_artist"))
				if clay.UI_WithId(clay.ID("footer_artist"))(
				{layout = {sizing = {width = clay.SizingFit({})}}},
				) {
					clay.Text(
						view.status,
						clay.TextElementConfig {
							fontSize = 12,
							textColor = artist_over ? WHITE : MUTED,
							wrapMode = .None,
						},
					)
				}
			}
		}
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childGap = u16(8 * d),
				childAlignment = {x = .Center, y = .Center},
			},
		},
		) {
			if clay.UI()(
			{layout = {childGap = u16(8 * d), childAlignment = {x = .Center, y = .Center}}},
			) {
				icon_button(
					"footer_shuffle",
					"shuffle",
					view.shuffle ? .Green : .Muted,
					textures,
					fx,
					d,
					icon_size = 18,
				)
				icon_button(
					"footer_previous",
					"skip-back-filled",
					.White,
					textures,
					fx,
					d,
					icon_size = 18,
				)
				round_play_button(
					"footer_play",
					view.button == "pause" ? "pause-filled" : "play-filled",
					textures,
					fx,
					d,
					44,
					18,
					WHITE,
					FOOTER_HOVER,
				)
				icon_button(
					"footer_next",
					"skip-forward-filled",
					.White,
					textures,
					fx,
					d,
					icon_size = 18,
				)
				icon_button(
					"footer_repeat",
					"repeat",
					view.repeat ? .Green : .Muted,
					textures,
					fx,
					d,
					icon_size = 18,
				)
			}
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingGrow({max = SEEK_MAX_WIDTH * d})},
					childGap = u16(10 * d),
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(
					view.elapsed,
					clay.TextElementConfig{fontId = 1, fontSize = 12, textColor = MUTED},
				)
				if clay.UI_WithId(clay.ID("seek_slider"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(24 * d)},
						childAlignment = {y = .Center},
					},
				},
				) {
					if clay.UI()(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingFixed(4 * d),
							},
						},
						backgroundColor = CARD,
						cornerRadius = clay.CornerRadiusAll(2 * d),
					},
					) {
						if view.progress > 0 {
							clay.UI()(
							{
								layout = {
									sizing = {
										width = clay.SizingPercent(view.progress),
										height = clay.SizingFixed(4 * d),
									},
								},
								backgroundColor = WHITE,
								cornerRadius = clay.CornerRadiusAll(2 * d),
							},
							)
						}
					}
				}
				clay.Text(
					view.total,
					clay.TextElementConfig{fontId = 1, fontSize = 12, textColor = MUTED},
				)
			}
		}
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(180 * d), height = clay.SizingGrow({})},
				childGap = u16(10 * d),
				childAlignment = {x = .Right, y = .Center},
			},
		},
		) {
			icon_button(
				"footer_devices",
				"speaker",
				view.device_active ? .Green : .Muted,
				textures,
				fx,
				d,
				icon_size = 18,
			)
			icon_element(textures, "volume-2", .Muted, 18 * d)
			if clay.UI_WithId(clay.ID("volume_slider"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(90 * d), height = clay.SizingFixed(24 * d)},
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI()(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(90 * d),
							height = clay.SizingFixed(4 * d),
						},
					},
					backgroundColor = CARD,
					cornerRadius = clay.CornerRadiusAll(2 * d),
				},
				) {
					clay.UI()(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(90 * d * view.volume),
								height = clay.SizingFixed(4 * d),
							},
						},
						backgroundColor = WHITE,
						cornerRadius = clay.CornerRadiusAll(2 * d),
					},
					)
				}
			}
		}
	}
}

// Middle-click autoscroll parks a small anchor where the button went down;
// steering the mouse away scrolls that container until another click lands.
autoscroll_indicator :: proc(view: View, textures: ^Textures, d: f32) {
	if !view.scroll_active {return}
	size := 40 * d
	if clay.UI_WithId(clay.ID("autoscroll"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)},
			childAlignment = {x = .Center, y = .Center},
		},
		floating = {
			offset = {view.scroll_x - size / 2, view.scroll_y - size / 2},
			zIndex = 11,
			attachTo = .Root,
		},
		backgroundColor = clay.Color{12, 12, 12, 220},
		cornerRadius = clay.CornerRadiusAll(size / 2),
	},
	) {
		icon_element(textures, "chevrons-up-down", .White, 20 * d)
	}
}

// A small label that follows the pointer while a track is dragged onto a
// playlist card. Passthrough so it never steals the pointer from the target.
drag_ghost :: proc(view: View, d: f32) {
	if !view.drag_active || len(view.drag_label) == 0 {return}
	if clay.UI_WithId(clay.ID("drag_ghost"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({max = 220 * d}), height = clay.SizingFixed(34 * d)},
			padding = {left = u16(12 * d), right = u16(12 * d)},
			childAlignment = {y = .Center},
		},
		floating = {
			offset = {view.drag_x + 14 * d, view.drag_y + 14 * d},
			zIndex = 20,
			attachTo = .Root,
			pointerCaptureMode = .Passthrough,
		},
		backgroundColor = PANEL,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		clay.Text(
			view.drag_label,
			clay.TextElementConfig{fontSize = 14, textColor = WHITE, wrapMode = .None},
		)
	}
}

// Transient feedback for a playlist write, anchored above the player bar.
// Passthrough so it never blocks a click.
toast_banner :: proc(view: View, d: f32) {
	if len(view.toast) == 0 {return}
	if clay.UI_WithId(clay.ID("toast"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({max = 420 * d}), height = clay.SizingFixed(40 * d)},
			padding = {left = u16(16 * d), right = u16(16 * d)},
			childAlignment = {x = .Center, y = .Center},
		},
		floating = {
			offset = {0, -110 * d},
			zIndex = 30,
			attachTo = .Root,
			attachment = {element = .CenterBottom, parent = .CenterBottom},
			pointerCaptureMode = .Passthrough,
		},
		backgroundColor = PANEL,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		clay.Text(view.toast, clay.TextElementConfig{fontSize = 14, textColor = WHITE})
	}
}

// The app is unusable until the account is approved, so sign-in takes over
// the whole window instead of sharing it with an empty library.
sign_in_pending :: proc(state: library.State) -> bool {
	return state == .Authorizing || state == .Sign_In_Failed || state == .Missing_Client_ID
}

// First-run setup stores the personal Spotify app key in the system
// keyring, so no environment variable is needed afterwards.
SPOTIFY_DASHBOARD :: "https://developer.spotify.com/dashboard"

sign_in_screen :: proc(
	state: library.State,
	browser_ready: bool,
	setup_input, setup_error: string,
	d: f32,
) {
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			padding = clay.PaddingAll(u16(32 * d)),
			childGap = u16(12 * d),
			childAlignment = {x = .Center, y = .Center},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFit({})},
				childGap = u16(12 * d),
				childAlignment = {x = .Center},
			},
		},
		) {
			title := "Signing in..."
			line := "Checking your saved Spotify approval."
			button_id, button_label := "", ""
			if state == .Missing_Client_ID {
				setup_screen(setup_input, setup_error, d)
			} else {
				switch state {
				case .Authorizing:
					if browser_ready {
						title = "Connect to Spotify"
						line = "Approve access in your browser to load your library."
						button_id, button_label = "library_sign_in", "Sign in with Spotify"
					}
				case .Sign_In_Failed:
					title = "Could not sign in"
					line = "Browser approval did not complete."
					button_id, button_label = "library_retry", "Try again"
				case .Idle, .Loading, .Ready, .Missing_Client_ID, .Failed:
				}
				clay.Text(title, clay.TextElementConfig{fontSize = 28, textColor = WHITE})
				clay.Text(line, clay.TextElementConfig{fontSize = 14, textColor = MUTED})
				if len(button_id) > 0 {
					sign_in_button(button_id, button_label, d)
				}
			}
		}
	}
}

setup_screen :: proc(setup_input, setup_error: string, d: f32) {
	clay.Text("Connect your Spotify app", clay.TextElementConfig{fontSize = 28, textColor = WHITE})
	clay.Text(
		"spoti reads your account through your own Spotify app.",
		clay.TextElementConfig{fontSize = 14, textColor = MUTED},
	)
	clay.Text(
		"1. Open the Spotify dashboard and create an app.",
		clay.TextElementConfig{fontSize = 14, textColor = MUTED},
	)
	clay.Text(
		"2. Add this redirect URI in the app settings:",
		clay.TextElementConfig{fontSize = 14, textColor = MUTED},
	)
	clay.Text(oauth.WEB_REDIRECT_URI, clay.TextElementConfig{fontSize = 14, textColor = WHITE})
	clay.Text(
		"3. Paste the 32-character client id below and save.",
		clay.TextElementConfig{fontSize = 14, textColor = MUTED},
	)
	if clay.UI_WithId(clay.ID("setup_field"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(40 * d)},
			padding = {left = u16(16 * d), right = u16(16 * d)},
			childAlignment = {y = .Center},
		},
		backgroundColor = CARD,
		cornerRadius = clay.CornerRadiusAll(20 * d),
	},
	) {
		if len(setup_input) > 0 {
			clay.Text(setup_input, clay.TextElementConfig{fontSize = 14, textColor = WHITE})
		} else {
			clay.Text(
				"paste your client id",
				clay.TextElementConfig{fontSize = 14, textColor = MUTED},
			)
		}
	}
	if len(setup_error) > 0 {
		clay.Text(setup_error, clay.TextElementConfig{fontSize = 14, textColor = WHITE})
	}
	if clay.UI()(
	{
		layout = {
			layoutDirection = .LeftToRight,
			sizing = {width = clay.SizingFit({})},
			childGap = u16(12 * d),
		},
	},
	) {
		sign_in_button("setup_dashboard", "Open dashboard", d)
		sign_in_button("setup_save", "Save and continue", d)
	}
}

sign_in_button :: proc(id, label: string, d: f32) {
	if clay.UI_WithId(clay.ID(id))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(40 * d)},
			padding = {left = u16(20 * d), right = u16(20 * d)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.PointerOver(clay.ID(id)) ? HERO_HOVER : GREEN,
		cornerRadius = clay.CornerRadiusAll(20 * d),
	},
	) {
		// Spotify green keeps dark text in both themes, like the hero play icon.
		clay.Text(label, clay.TextElementConfig{fontSize = 14, textColor = {18, 18, 18, 255}})
	}
}

layout :: proc(
	view: View,
	client: ^library.Client,
	app_state: ^State,
	filter: library.Kind,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	sidebar_width, viewport_width, viewport_height, card_text_height, dt, d: f32,
	ui_state: ^ui.State,
) -> (
	clay.ClayArray(clay.RenderCommand),
	Frame_Visible,
) {
	visible: Frame_Visible
	clay.SetLayoutDimensions({viewport_width, viewport_height})
	clay.BeginLayout()
	if sign_in_pending(client.state) {
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BG,
		},
		) {
			sign_in_screen(client.state, view.sign_in, view.input, view.setup_error, d)
		}
	} else if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
		},
		backgroundColor = BG,
	},
	) {
		top_bar(view, textures, fx, d)
		if clay.UI()(
		{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}}},
		) {
			library_tabs := LIBRARY_TABS
			library_labels := LIBRARY_TAB_LABELS
			search_tabs := SEARCH_TABS
			search_labels := SEARCH_TAB_LABELS
			page := &client.pages[filter]
			tabs := library_tabs[:]
			labels := library_labels[:]
			active := filter
			if view.search_mode {
				page = &client.search_pages[view.search_kind]
				tabs = search_tabs[:]
				labels = search_labels[:]
				active = view.search_kind
			}
			visible.cards = sidebar(
				client,
				app_state,
				ui_state,
				page,
				tabs,
				labels,
				active,
				view.search_mode,
				textures,
				sidebar_width,
				viewport_height,
				card_text_height,
				d,
				dt,
				view.drag_active ? view.drop_target : -1,
			)
			if clay.UI_WithId(clay.ID("sidebar_handle"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(6 * d), height = clay.SizingGrow({})},
				},
				backgroundColor = BG,
			},
			) {}
			detail_page(
				view,
				client,
				textures,
				fx,
				viewport_width - (sidebar_width + 6) * d,
				viewport_height,
				card_text_height,
				dt,
				d,
				ui_state,
				&visible,
			)
		}
		// Breathing room between the content row and the player bar.
		if clay.UI()(
		{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(8 * d)}}},
		) {}
		player_bar(view, textures, fx, d)
		scrollbar("library_grid", "library_scrollbar", d)
		scrollbar("detail_rows", "detail_scrollbar", d)
		context_menu(view, textures, d)
		device_panel(view, textures, d)
		drag_ghost(view, d)
		toast_banner(view, d)
		autoscroll_indicator(view, textures, d)
	}
	return clay.EndLayout(dt), visible
}
