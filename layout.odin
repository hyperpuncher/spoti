package main

import library "spotify/library"
import clay "vendor/clay"

BG :: clay.Color{18, 18, 18, 255}
SIDEBAR :: clay.Color{24, 24, 24, 255}
PANEL :: clay.Color{32, 32, 32, 255}
CARD :: clay.Color{45, 45, 45, 255}
HOVER :: clay.Color{52, 52, 52, 255}
SELECTED :: clay.Color{36, 36, 36, 255}
PLAYER :: clay.Color{12, 12, 12, 255}
WHITE :: clay.Color{245, 245, 245, 255}
MUTED :: clay.Color{165, 165, 165, 255}
GREEN :: clay.Color{30, 215, 96, 255}

SIDEBAR_MIN :: 284
SIDEBAR_MAX :: 640
// The player seek bar stays a comfortable length on very wide windows.
SEEK_MAX_WIDTH :: 620

LIBRARY_TABS :: [3]library.Kind{.Playlists, .Albums, .Artists}
LIBRARY_TAB_LABELS :: [3]string{"Playlists", "Albums", "Artists"}
SEARCH_TABS :: [4]library.Kind{.Playlists, .Albums, .Artists, .Tracks}
SEARCH_TAB_LABELS :: [4]string{"Playlists", "Albums", "Artists", "Tracks"}

View :: struct {
	title:         string,
	status:        string,
	button:        string,
	progress:      f32,
	elapsed:       string,
	total:         string,
	input:         string,
	cover:         string,
	repeat:        bool,
	shuffle:       bool,
	volume:        f32,
	input_active:  bool,
	pinned:        bool,
	search_mode:   bool,
	search_kind:   library.Kind,
	menu_open:     bool,
	menu_x:        f32,
	menu_y:        f32,
	menu_count:    int,
	menu_labels:   [2]string,
	scroll_active: bool, // middle-click autoscroll anchor indicator
	scroll_x:      f32,
	scroll_y:      f32,
}

chip :: proc(label: string, id: u32, active: bool, d: f32) {
	if clay.UI_WithId(clay.ID("chip", id))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(32 * d)},
			padding = clay.PaddingAll(u16(14 * d)),
			childAlignment = {y = .Center},
		},
		backgroundColor = active ? WHITE : CARD,
		cornerRadius = clay.CornerRadiusAll(16 * d),
	},
	) {
		clay.Text(label, clay.TextElementConfig{fontSize = 14, textColor = active ? BG : WHITE})
	}
}

toolbar_button :: proc(id, icon: string, textures: ^Textures, tint: Icon_Tint, d: f32) {
	if clay.UI_WithId(clay.ID(id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(40 * d), height = clay.SizingFixed(40 * d)},
			childAlignment = {x = .Center, y = .Center},
		},
		cornerRadius = clay.CornerRadiusAll(20 * d),
	},
	) {
		icon_element(textures, icon, tint, 20 * d)
	}
}

top_bar :: proc(view: View, textures: ^Textures, d: f32) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(58 * d)},
			padding = {left = u16(10 * d), right = u16(10 * d)},
			childAlignment = {y = .Center},
			childGap = u16(4 * d),
		},
		backgroundColor = BG,
	},
	) {
		toolbar_button("toolbar_back", "chevron-left", textures, .Muted, d)
		toolbar_button("toolbar_library", "library", textures, .Muted, d)
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
}

player_control :: proc(id, icon: string, tint: Icon_Tint, textures: ^Textures, d: f32) {
	if clay.UI_WithId(clay.ID(id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(32 * d), height = clay.SizingFixed(32 * d)},
			childAlignment = {x = .Center, y = .Center},
		},
		cornerRadius = clay.CornerRadiusAll(16 * d),
	},
	) {
		icon_element(textures, icon, tint, 18 * d)
	}
}

player_bar :: proc(view: View, textures: ^Textures, d: f32) {
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
				clay.Text(
					view.title,
					clay.TextElementConfig{fontSize = 15, textColor = WHITE, wrapMode = .None},
				)
				clay.Text(
					view.status,
					clay.TextElementConfig{fontSize = 12, textColor = MUTED, wrapMode = .None},
				)
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
				player_control(
					"footer_shuffle",
					"shuffle",
					view.shuffle ? .Green : .Muted,
					textures,
					d,
				)
				player_control("footer_previous", "skip-back", .White, textures, d)
				if clay.UI_WithId(clay.ID("footer_play"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(44 * d),
							height = clay.SizingFixed(44 * d),
						},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = WHITE,
					cornerRadius = clay.CornerRadiusAll(22 * d),
				},
				) {
					icon_element(
						textures,
						view.button == "pause" ? "pause-filled" : "play-filled",
						.Dark,
						18 * d,
					)
				}
				player_control("footer_next", "skip-forward", .White, textures, d)
				player_control(
					"footer_repeat",
					"repeat",
					view.repeat ? .Green : .Muted,
					textures,
					d,
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

layout :: proc(
	view: View,
	client: ^library.Client,
	settings: ^Settings,
	filter: library.Kind,
	textures: ^Textures,
	sidebar_width, viewport_width, viewport_height, card_text_height, dt, d: f32,
) -> (
	clay.ClayArray(clay.RenderCommand),
	Frame_Visible,
) {
	visible: Frame_Visible
	clay.BeginLayout()
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
		},
		backgroundColor = BG,
	},
	) {
		top_bar(view, textures, d)
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
				settings,
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
				viewport_width - (sidebar_width + 6) * d,
				viewport_height,
				card_text_height,
				d,
				&visible,
			)
		}
		player_bar(view, textures, d)
		scrollbar("library_grid", "library_scrollbar", d)
		scrollbar("detail_rows", "detail_scrollbar", d)
		context_menu(view, d)
		autoscroll_indicator(view, textures, d)
	}
	return clay.EndLayout(dt), visible
}
