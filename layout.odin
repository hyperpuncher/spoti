package main

import library "spotify/library"
import oauth "spotify/oauth"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

// Active palette, updated on startup and SDL_EVENT_SYSTEM_THEME_CHANGED.
theme := DARK_THEME

Theme :: struct {
	bg:           clay.Color,
	sidebar:      clay.Color,
	panel:        clay.Color,
	card:         clay.Color,
	keycap:       clay.Color,
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
	keycap       = {45, 45, 45, 255},
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
	keycap       = {255, 255, 255, 255},
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
	theme = dark ? DARK_THEME : LIGHT_THEME
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
	input_editor:   ^ui.Editor, // borrowed until this frame is rendered
	setup_error:    string, // borrowed; setup screen error line
	caption_width:  f32, // native Windows controls, render pixels
	album_linked:   bool, // footer title opens the playing album
	artist_linked:  bool, // footer artist opens the playing artist
	pinned:         bool,
	sign_in:        bool, // a library browser approval is waiting for a click
	can_back:       bool,
	can_forward:    bool,
	search_mode:    bool,
	releases:       bool,
	search_kind:    library.Kind,
	menu:           ^Context_Menu, // borrowed while layout runs
	queue_open:     bool,
	queue_items:    []Play_Item, // borrowed; playback owns the queue
	queue_index:    int,
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
		backgroundColor = active ? theme.text : clay.PointerOver(clay.ID("chip", id)) ? theme.hover : theme.card,
		cornerRadius = clay.CornerRadiusAll(16 * d),
	},
	) {
		clay.Text(label, {fontSize = 14, textColor = active ? theme.bg : theme.text})
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
	anims:      ^map[u32]Button_Fx,
	mouse_down: bool,
	animating:  bool, // a UI animation is running; main keeps frames coming
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
	element_id := clay.ID(id)
	hovered = clay.PointerOver(element_id)
	if !enabled {return scale, false}
	fx := ctx.anims[element_id.id]
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
	ctx.anims[element_id.id] = fx
	return scale, hovered
}

input_text :: proc(view: View) {
	if view.input_editor == nil {
		clay.Text(view.input, {fontSize = 14, textColor = theme.muted, wrapMode = .None})
		return
	}
	view.input_editor.placeholder = view.input
	clay.UI_WithId(clay.ID("input_content"))(
	{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
		custom = {customData = view.input_editor},
	},
	)
}

search_input :: proc(view: View, textures: ^Textures, width: clay.SizingAxis, d: f32) {
	has_text := view.input_editor != nil && len(view.input_editor.input) > 0
	if clay.UI_WithId(clay.ID("track_input"))(
	{
		layout = {
			sizing = {width = width, height = clay.SizingFixed(40 * d)},
			padding = {left = u16(12 * d), right = u16(8 * d)},
			childAlignment = {y = .Center},
			childGap = u16(8 * d),
		},
		backgroundColor = view.input_active ? theme.card : theme.panel,
		cornerRadius = clay.CornerRadiusAll(20 * d),
	},
	) {
		icon_element(textures, "search", .Muted, 16 * d)
		input_text(view)
		if has_text {
			hovered := clay.PointerOver(clay.ID("search_clear"))
			if clay.UI_WithId(clay.ID("search_clear"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(68 * d), height = clay.SizingFixed(28 * d)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered ? theme.hover : clay.Color{},
				cornerRadius = clay.CornerRadiusAll(14 * d),
			},
			) {
				icon_element(textures, "x", hovered ? .White : .Muted, 16 * d)
			}
		} else if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(68 * d), height = clay.SizingFixed(18 * d)},
				childAlignment = {x = .Center, y = .Center},
				childGap = u16(3 * d),
			},
		},
		) {
			if !view.input_active {
				for key, index in ([2]string{"ctrl", "k"}) {
					if clay.UI()(
					{
						layout = {
							sizing = {height = clay.SizingFixed(18 * d)},
							padding = {left = u16(6 * d), right = u16(6 * d)},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = theme.keycap,
						cornerRadius = clay.CornerRadiusAll(5 * d),
					},
					) {
						if ODIN_OS == .Darwin && index == 0 {
							icon_element(textures, "command", .Muted, 11 * d)
						} else {
							clay.Text(
								key,
								{
									fontId = 1,
									fontSize = 11,
									textColor = theme.muted,
									wrapMode = .None,
									userData = &LABEL_INK_BOUNDS,
								},
							)
						}
					}
				}
			}
		}
	}
}

top_bar :: proc(view: View, textures: ^Textures, fx: ^Button_Fx_Ctx, d: f32) {
	padding := u16(10 * d)
	search_width := clay.SizingFixed(440 * d)
	when ODIN_OS == .Darwin {
		padding = u16(96 * d)
		search_width = clay.SizingGrow({min = 160 * d, max = 440 * d})
	}
	when ODIN_OS == .Windows {
		padding = u16(view.caption_width + 10 * d)
		search_width = clay.SizingGrow({min = 160 * d, max = 440 * d})
	}
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(58 * d)},
			padding = {left = padding, right = padding},
			childAlignment = {x = .Center, y = .Center},
			childGap = u16(4 * d),
		},
		backgroundColor = theme.bg,
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
		search_input(view, textures, search_width, d)
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
			backgroundColor = !enabled ? theme.card : over ? hover : background,
			cornerRadius = clay.CornerRadiusAll(size * d * scale / 2),
		},
		) {
			icon_element(textures, icon, enabled ? .Dark : .Disabled, icon_size * d * scale)
		}
	}
}

player_bar :: proc(
	view: View,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	ui_state: ^ui.State,
	width, d: f32,
) {
	padding, gap, cover_gap := u16(14 * d), u16(20 * d), u16(12 * d)
	// Share space beyond the seek bar's cap between both sides so controls
	// stay in place while the title and artist can use the empty left area.
	extra := max(f32(0), (width - 2 * f32(padding + gap) - (320 + 220 + SEEK_MAX_WIDTH) * d) / 2)
	left_width := 320 * d + extra
	text_width := left_width - 64 * d - f32(cover_gap)
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(92 * d)},
			padding = clay.PaddingAll(padding),
			childGap = gap,
			childAlignment = {y = .Center},
		},
		backgroundColor = theme.player,
	},
	) {
		if clay.UI_WithId(clay.ID("footer_metadata"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(left_width), height = clay.SizingGrow({})},
				childGap = cover_gap,
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
				backgroundColor = theme.card,
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
			},
			) {
				// Hug boxes so exactly the text is clickable. The title is
				// already white; the pointer alone marks it, while the
				// artist brightens like every other quiet icon.
				if clay.UI_WithId(clay.ID("footer_title"))(
				{layout = {sizing = {width = clay.SizingFit({})}}},
				) {
					fitted_text(
						ui_state,
						view.title,
						text_width,
						{fontSize = 15, textColor = theme.text, wrapMode = .None},
					)
				}
				artist_over := view.artist_linked && clay.PointerOver(clay.ID("footer_artist"))
				if clay.UI_WithId(clay.ID("footer_artist"))(
				{layout = {sizing = {width = clay.SizingFit({})}}},
				) {
					fitted_text(
						ui_state,
						view.status,
						text_width,
						{
							fontSize = 12,
							textColor = artist_over ? theme.text : theme.muted,
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
					theme.text,
					theme.footer_hover,
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
				clay.Text(view.elapsed, {fontId = 1, fontSize = 12, textColor = theme.muted})
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
						backgroundColor = theme.card,
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
								backgroundColor = theme.text,
								cornerRadius = clay.CornerRadiusAll(2 * d),
							},
							)
						}
					}
				}
				clay.Text(view.total, {fontId = 1, fontSize = 12, textColor = theme.muted})
			}
		}
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(220 * d + extra), height = clay.SizingGrow({})},
				childGap = u16(10 * d),
				childAlignment = {x = .Right, y = .Center},
			},
		},
		) {
			icon_button(
				"footer_queue",
				"list-music",
				view.queue_open ? .Green : .Muted,
				textures,
				fx,
				d,
				icon_size = 18,
			)
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
					backgroundColor = theme.card,
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
						backgroundColor = theme.text,
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
	// Fill with the text color so the opposite icon tint contrasts in both
	// themes; dark mode flips the badge to a light circle.
	background := theme.text
	background.a = 220
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
		backgroundColor = background,
		cornerRadius = clay.CornerRadiusAll(size / 2),
	},
	) {
		icon_element(textures, "chevrons-up-down", .Dark, 20 * d)
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
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		clay.Text(view.drag_label, {fontSize = 14, textColor = theme.text, wrapMode = .None})
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
		backgroundColor = theme.text,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		clay.Text(view.toast, {fontSize = 14, textColor = theme.bg})
	}
}

// First-run setup stores the personal Spotify app key in the system
// keyring, so no environment variable is needed afterwards.
SPOTIFY_DASHBOARD :: "https://developer.spotify.com/dashboard"

sign_in_screen :: proc(state: library.State, view: View, textures: ^Textures, d: f32) {
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
		if state == .Missing_Client_ID {
			setup_screen(view, textures, d)
		} else if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFit({})},
				childGap = u16(12 * d),
				childAlignment = {x = .Center},
			},
		},
		) {
			title := "Connect to Spotify"
			line := "Approve access in your browser to load your library."
			button_id, button_label := "", ""
			switch state {
			case .Authorizing:
				button_id, button_label = "library_sign_in", "Sign in with Spotify"
			case .Sign_In_Failed:
				title = "Could not sign in"
				line = "Browser approval did not complete."
				button_id, button_label = "library_retry", "Try again"
			case .Idle, .Loading, .Ready, .Missing_Client_ID, .Failed:
			}
			clay.Text(title, {fontSize = 28, textColor = theme.text})
			clay.Text(line, {fontSize = 14, textColor = theme.muted})
			if len(button_id) > 0 {
				sign_in_button(button_id, button_label, d)
			}
		}
	}
}

Setup_Step_Kind :: enum {
	Dashboard,
	Redirect,
	Client_ID,
}

setup_step :: proc(
	kind: Setup_Step_Kind,
	number, title, detail: string,
	view: View,
	textures: ^Textures,
	d: f32,
) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({})},
			childGap = u16(12 * d),
			childAlignment = {y = .Top},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(26 * d), height = clay.SizingFixed(26 * d)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = theme.bg,
			cornerRadius = clay.CornerRadiusAll(13 * d),
		},
		) {
			clay.Text(
				number,
				{fontId = 1, fontSize = 13, textColor = theme.muted, userData = &LABEL_INK_BOUNDS},
			)
		}
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({})},
				childGap = u16(8 * d),
			},
		},
		) {
			if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = u16(3 * d)}}) {
				clay.Text(title, {fontId = 3, fontSize = 14, textColor = theme.text})
				clay.Text(detail, {fontSize = 13, textColor = theme.muted, wrapMode = .Words})
			}
			switch kind {
			case .Dashboard:
				sign_in_button("setup_dashboard", "Open dashboard", d)
			case .Redirect:
				hovered := clay.PointerOver(clay.ID("setup_redirect"))
				if clay.UI_WithId(clay.ID("setup_redirect"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(42 * d)},
						padding = {left = u16(14 * d), right = u16(14 * d)},
						childAlignment = {y = .Center},
						childGap = u16(8 * d),
					},
					backgroundColor = hovered ? theme.hover : theme.bg,
					cornerRadius = clay.CornerRadiusAll(10 * d),
				},
				) {
					clay.Text(
						oauth.WEB_REDIRECT_URI,
						{fontId = 1, fontSize = 13, textColor = theme.text, wrapMode = .None},
					)
					if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {}
					icon_element(textures, "copy", hovered ? .White : .Muted, 16 * d)
				}
			case .Client_ID:
				if clay.UI_WithId(clay.ID("setup_field"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(42 * d)},
						padding = {left = u16(14 * d), right = u16(14 * d)},
						childAlignment = {y = .Center},
					},
					backgroundColor = theme.bg,
					cornerRadius = clay.CornerRadiusAll(10 * d),
				},
				) {
					if len(view.input) > 0 || view.input_active {
						input_text(view)
					} else {
						clay.Text(
							"Paste the 32-character Client ID",
							{fontSize = 14, textColor = theme.muted, wrapMode = .None},
						)
					}
				}
				if len(view.setup_error) > 0 {
					if clay.UI()(
					{
						layout = {
							sizing = {width = clay.SizingGrow({})},
							padding = {
								left = u16(12 * d),
								right = u16(12 * d),
								top = u16(9 * d),
								bottom = u16(9 * d),
							},
						},
						backgroundColor = theme.bg,
						cornerRadius = clay.CornerRadiusAll(8 * d),
					},
					) {
						clay.Text(
							view.setup_error,
							{fontId = 3, fontSize = 13, textColor = theme.text, wrapMode = .Words},
						)
					}
				}
			}
		}
	}
}

setup_screen :: proc(view: View, textures: ^Textures, d: f32) {
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({max = 560 * d})},
			padding = clay.PaddingAll(u16(32 * d)),
			childGap = u16(24 * d),
		},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(18 * d),
	},
	) {
		if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = u16(6 * d)}}) {
			clay.Text(
				"Connect your Spotify app",
				{fontId = 2, fontSize = 28, textColor = theme.text},
			)
			clay.Text(
				"Create a Spotify developer app and give spoti its Client ID.",
				{fontSize = 14, textColor = theme.muted, wrapMode = .Words},
			)
		}
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({})},
				childGap = u16(20 * d),
			},
		},
		) {
			setup_step(
				.Dashboard,
				"1",
				"Create a Spotify app with Web API",
				"Name and description can be anything.\nUnder \"Which API/SDKs are you planning to use?\", select \"Web API\".",
				view,
				textures,
				d,
			)
			setup_step(
				.Redirect,
				"2",
				"Add the redirect URI",
				`Add this exact URI under "Redirect URIs" in the app settings.`,
				view,
				textures,
				d,
			)
			setup_step(
				.Client_ID,
				"3",
				"Paste the Client ID",
				`Open your new app, copy "Client ID", and paste it here.`,
				view,
				textures,
				d,
			)
		}
		sign_in_button("setup_save", "Save and continue", d, grow = true)
	}
}

sign_in_button :: proc(id, label: string, d: f32, grow := false) {
	if clay.UI_WithId(clay.ID(id))(
	{
		layout = {
			sizing = {
				width = grow ? clay.SizingGrow({}) : clay.SizingFit({}),
				height = clay.SizingFixed(40 * d),
			},
			padding = {left = u16(20 * d), right = u16(20 * d)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.PointerOver(clay.ID(id)) ? theme.hero_hover : theme.green,
		cornerRadius = clay.CornerRadiusAll(20 * d),
	},
	) {
		// Spotify green keeps dark text in both themes, like the hero play icon.
		clay.Text(label, {fontSize = 14, textColor = {18, 18, 18, 255}})
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
	hero_cache: ^Hero_Cache = nil,
) -> (
	clay.ClayArray(clay.RenderCommand),
	Frame_Visible,
) {
	visible: Frame_Visible
	clay.SetLayoutDimensions({viewport_width, viewport_height})
	clay.BeginLayout()
	if client.state == .Missing_Client_ID ||
	   client.state == .Sign_In_Failed ||
	   client.state == .Authorizing && view.sign_in {
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = theme.bg,
		},
		) {
			sign_in_screen(client.state, view, textures, d)
			toast_banner(view, d)
		}
	} else if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			// Page minimum sizes must not expand the shared toolbar and player.
			sizing = {
				width = clay.SizingFixed(viewport_width),
				height = clay.SizingFixed(viewport_height),
			},
		},
		backgroundColor = theme.bg,
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
				backgroundColor = theme.bg,
			},
			) {}
			detail_width := max(0, viewport_width - (sidebar_width + 6) * d)
			queue_width: f32
			if view.queue_open {
				// A narrow window gives the queue the detail pane instead of
				// compressing both lists below a readable width.
				queue_width =
					detail_width < (QUEUE_WIDTH + 280) * d ? detail_width : QUEUE_WIDTH * d
				detail_width -= queue_width
			}
			if !view.queue_open || detail_width > 0 {
				detail_page(
					view,
					client,
					textures,
					fx,
					detail_width,
					viewport_height,
					card_text_height,
					dt,
					d,
					ui_state,
					&visible,
					hero_cache,
				)
			}
			if view.queue_open {
				visible.queue = queue_panel(
					view,
					textures,
					fx,
					queue_width,
					viewport_height,
					d,
					ui_state,
				)
			}
		}
		// Breathing room between the content row and the player bar.
		if clay.UI()(
		{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(8 * d)}}},
		) {}
		player_bar(view, textures, fx, ui_state, viewport_width, d)
		scrollbar("library_grid", "library_scrollbar", d)
		scrollbar("detail_rows", "detail_scrollbar", d)
		if view.queue_open {scrollbar("queue_rows", "queue_scrollbar", d)}
		context_menu(view.menu, textures, ui_state, viewport_width, viewport_height, d)
		device_panel(view, textures, d)
		drag_ghost(view, d)
		toast_banner(view, d)
		autoscroll_indicator(view, textures, d)
	}
	return clay.EndLayout(dt), visible
}
