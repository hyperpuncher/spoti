package main

import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

QUEUE_WIDTH :: 320
QUEUE_ROW_HEIGHT :: 56

queue_item_at :: proc(current: int, visible: Visible_Items, point: sdl.FPoint) -> int {
	if current >= 0 && hit("queue_current", point) {return current}
	for index in visible.first ..< visible.last {
		if hit_clipped("queue_item", "queue_rows", point, u32(index)) {return index}
	}
	return -1
}

queue_row :: proc(item: Play_Item, index: int, current: bool, width, d: f32, ui_state: ^ui.State) {
	id := current ? clay.ID("queue_current") : clay.ID("queue_item", u32(index))
	if clay.UI_WithId(id)(
	{
		layout = {
			sizing = {
				width = clay.SizingGrow({}),
				height = clay.SizingFixed(QUEUE_ROW_HEIGHT * d),
			},
			padding = {left = u16(8 * d), right = u16(8 * d)},
			childGap = u16(8 * d),
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.PointerOver(id) ? theme.hover : current ? theme.selected : clay.Color{},
		cornerRadius = clay.CornerRadiusAll(6 * d),
	},
	) {
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({})},
				childGap = u16(3 * d),
			},
		},
		) {
			text_width := max(0, width - 68 * d)
			fitted_text(
				ui_state,
				item.name != "" ? item.name : "Track title unavailable",
				text_width,
				{
					fontId = 3,
					fontSize = 14,
					textColor = current ? theme.green : theme.text,
					wrapMode = .None,
				},
			)
			fitted_text(
				ui_state,
				item.artist,
				text_width,
				{fontSize = 12, textColor = theme.muted, wrapMode = .None},
			)
		}
		if clay.UI()(
		{layout = {sizing = {width = clay.SizingFixed(36 * d)}, childAlignment = {x = .Right}}},
		) {
			if item.duration_ms >
			   0 {clay.Text(duration_text_alloc(item.duration_ms), {fontId = 1, fontSize = 12, textColor = theme.muted, wrapMode = .None})}
		}
	}
}

// Borrow the owned playback queue. Only upcoming visible rows enter layout;
// opening this view never fetches tracks or artwork.
queue_panel :: proc(
	view: View,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	width, height, d: f32,
	ui_state: ^ui.State,
) -> (
	shown: Visible_Items,
) {
	if clay.UI_WithId(clay.ID("queue_panel"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(width), height = clay.SizingGrow({})},
			padding = {
				left = u16(12 * d),
				right = u16((12 + SCROLLBAR_OUTSET) * d),
				top = u16(8 * d),
				bottom = u16(12 * d),
			},
			childGap = u16(12 * d),
		},
		backgroundColor = theme.sidebar,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(36 * d)},
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI()(
			{layout = {sizing = {width = clay.SizingGrow({})}}},
			) {clay.Text("Queue", {fontId = 2, fontSize = 20, textColor = theme.text})}
			icon_button("queue_close", "chevron-right", .Muted, textures, fx, d, icon_size = 18)
		}
		current := view.queue_index >= 0 && view.queue_index < len(view.queue_items)
		row_width := width - (24 + SCROLLBAR_OUTSET) * d
		if current {
			clay.Text(
				view.playing ? "Now playing" : "Current track",
				{fontId = 3, fontSize = 14, textColor = theme.text},
			)
			queue_row(
				view.queue_items[view.queue_index],
				view.queue_index,
				true,
				row_width,
				d,
				ui_state,
			)
		}
		start := current ? view.queue_index + 1 : 0
		if start == len(view.queue_items) {
			clay.Text(
				current ? "No upcoming tracks" : "Your queue is empty",
				{fontSize = 14, textColor = theme.muted},
			)
			return
		}
		clay.Text("Next up", {fontId = 3, fontSize = 14, textColor = theme.text})
		if clay.UI_WithId(clay.ID("queue_rows"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			},
			clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			shown = scroll_items(
				"queue_rows",
				len(view.queue_items) - start,
				1,
				QUEUE_ROW_HEIGHT * d,
				height,
			)
			list_spacer(shown.before)
			for index in shown.first ..< shown.last {queue_row(view.queue_items[start + index], start + index, false, row_width, d, ui_state)}
			list_spacer(shown.after)
			shown.first += start
			shown.last += start
		}
	}
	return
}
