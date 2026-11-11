#include "text.h"
#include <pango/pangocairo.h>
#include <string.h>

struct St_Engine { PangoFontMap *map; PangoContext *context; };
struct St_Layout { PangoLayout *value; int length; };

St_Engine *st_open(const char *path) {
	St_Engine *engine = calloc(1, sizeof(*engine));
	if (!engine) return NULL;
	engine->map = pango_cairo_font_map_new();
	GError *error = NULL;
	if (!pango_font_map_add_font_file(engine->map, path, &error)) {
		g_clear_error(&error);
		st_close(engine);
		return NULL;
	}
	engine->context = pango_font_map_create_context(engine->map);
	// Transparent label textures need grayscale coverage, not LCD subpixels.
	cairo_font_options_t *options = cairo_font_options_create();
	cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
	cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_SLIGHT);
	cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF);
	pango_cairo_context_set_font_options(engine->context, options);
	cairo_font_options_destroy(options);
	return engine;
}

void st_close(St_Engine *engine) {
	if (!engine) return;
	g_clear_object(&engine->context);
	g_clear_object(&engine->map);
	free(engine);
}

St_Layout *st_layout(St_Engine *engine, const char *text, int length, float size, int weight) {
	if (!engine || length < 0 || !isfinite(size) || size <= 0 || !g_utf8_validate(text ? text : "", length, NULL)) return NULL;
	St_Layout *layout = calloc(1, sizeof(*layout));
	if (!layout) return NULL;
	layout->value = pango_layout_new(engine->context);
	layout->length = length;
	PangoFontDescription *desc = pango_font_description_new();
	pango_font_description_set_family(desc, "Geist");
	pango_font_description_set_absolute_size(desc, size * PANGO_SCALE);
	pango_font_description_set_weight(desc, weight);
	pango_layout_set_font_description(layout->value, desc);
	pango_font_description_free(desc);
	pango_layout_set_text(layout->value, text ? text : "", length);
	return layout;
}

void st_destroy(St_Layout *layout) {
	if (!layout) return;
	g_object_unref(layout->value);
	free(layout);
}

St_Metrics st_metrics(St_Layout *layout) {
	PangoRectangle ink, logical;
	pango_layout_get_extents(layout->value, &ink, &logical);
	return (St_Metrics){
		.width = (float)logical.width / PANGO_SCALE,
		.height = (float)logical.height / PANGO_SCALE,
		.baseline = (float)pango_layout_get_baseline(layout->value) / PANGO_SCALE,
		.ink = {(float)ink.x / PANGO_SCALE, (float)ink.y / PANGO_SCALE,
			(float)ink.width / PANGO_SCALE, (float)ink.height / PANGO_SCALE},
	};
}

int st_fit(St_Layout *layout, float width) {
	if (!isfinite(width) || width < 0) return -1;
	if (st_metrics(layout).width <= width) return layout->length;
	PangoLayout *copy = pango_layout_copy(layout->value);
	pango_layout_set_width(copy, (int)floorf(width * PANGO_SCALE));
	pango_layout_set_ellipsize(copy, PANGO_ELLIPSIZE_END);
	pango_layout_set_height(copy, -1);
	int actual;
	pango_layout_get_size(copy, &actual, NULL);
	int prefix = -1;
	if ((float)actual / PANGO_SCALE <= width) {
		PangoLayoutIter *iter = pango_layout_get_iter(copy);
		do {
			PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
			if (run && (run->item->analysis.flags & PANGO_ANALYSIS_FLAG_IS_ELLIPSIS)) {
				prefix = run->item->offset;
				break;
			}
		} while (pango_layout_iter_next_run(iter));
		pango_layout_iter_free(iter);
	}
	g_object_unref(copy);
	return prefix;
}

float st_cursor(St_Layout *layout, int index) {
	PangoRectangle strong;
	pango_layout_get_cursor_pos(layout->value, index, &strong, NULL);
	return (float)strong.x / PANGO_SCALE;
}

int st_hit(St_Layout *layout, float x, int nearest) {
	int index, trailing;
	int baseline = pango_layout_get_baseline(layout->value);
	pango_layout_xy_to_index(layout->value, (int)(x * PANGO_SCALE), baseline / 2, &index, &trailing);
	if (nearest) {
		const char *text = pango_layout_get_text(layout->value);
		index = (int)(g_utf8_offset_to_pointer(text + index, trailing) - text);
	}
	return index;
}

int st_selection(St_Layout *layout, int start, int end, St_Rect *rects, int capacity) {
	PangoLayoutLine *line = pango_layout_get_line_readonly(layout->value, 0);
	int *ranges, count;
	pango_layout_line_get_x_ranges(line, start, end, &ranges, &count);
	float height = st_metrics(layout).height;
	for (int i = 0; i < count && i < capacity; i++) {
		float x = (float)ranges[i * 2] / PANGO_SCALE;
		rects[i] = (St_Rect){x, 0, (float)(ranges[i * 2 + 1] - ranges[i * 2]) / PANGO_SCALE, height};
	}
	g_free(ranges);
	return count;
}

St_Image st_render(St_Layout *layout, uint8_t r, uint8_t g, uint8_t b) {
	St_Image image = st_image(st_metrics(layout).ink);
	if (!image.pixels) return image;
	cairo_surface_t *surface = cairo_image_surface_create_for_data(image.pixels,
		CAIRO_FORMAT_ARGB32, image.width, image.height, image.stride);
	cairo_t *cr = cairo_create(surface);
	cairo_set_source_rgb(cr, r / 255.0, g / 255.0, b / 255.0);
	cairo_move_to(cr, -image.x, -image.y);
	pango_cairo_show_layout(cr, layout->value);
	cairo_surface_flush(surface);
	int ok = cairo_status(cr) == CAIRO_STATUS_SUCCESS;
	cairo_destroy(cr);
	cairo_surface_destroy(surface);
	if (!ok) { free(image.pixels); image.pixels = NULL; }
	return image;
}

// Test diagnostic: the system must supply the script and emoji fonts.
int st_missing(St_Layout *layout) {
	return pango_layout_get_unknown_glyphs_count(layout->value);
}
int st_color_glyphs(St_Layout *layout) {
	int count = 0;
	PangoLayoutIter *iter = pango_layout_get_iter(layout->value);
	do {
		PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
		if (!run) continue;
		for (int i = 0; i < run->glyphs->num_glyphs; i++) {
			PangoGlyphInfo *glyph = &run->glyphs->glyphs[i];
			if (glyph->glyph != PANGO_GLYPH_EMPTY && glyph->attr.is_color) count++;
		}
	} while (pango_layout_iter_next_run(iter));
	pango_layout_iter_free(iter);
	return count;
}
