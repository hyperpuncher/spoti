#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite_3.h>
#include <d2d1.h>
#include <wincodec.h>
#include <float.h>
#include <string.h>
#include "text.h"

template<class T> static void release(T *&p) { if (p) p->Release(); p = nullptr; }
struct St_Engine {
	IDWriteFactory5 *write;
	IDWriteFontCollection1 *fonts;
	ID2D1Factory *draw;
	IWICImagingFactory *images;
	bool apartment;
};
struct St_Layout {
	St_Engine *engine;
	IDWriteTextLayout *value;
	char *text;
	int length;
	St_Metrics metrics;
};

St_Engine *st_open(const char *path) {
	St_Engine *e = (St_Engine *)calloc(1, sizeof(*e));
	if (!e) return nullptr;
	e->apartment = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
	int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
	WCHAR *wide = (WCHAR *)calloc(n, sizeof(WCHAR));
	IDWriteFontFile *file = nullptr;
	IDWriteFontSetBuilder1 *builder = nullptr;
	IDWriteFontSet *set = nullptr;
	bool ok = wide && n > 0 && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, n) &&
		SUCCEEDED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, __uuidof(IDWriteFactory5), (IUnknown **)&e->write)) &&
		SUCCEEDED(e->write->CreateFontFileReference(wide, nullptr, &file)) &&
		SUCCEEDED(e->write->CreateFontSetBuilder(&builder)) &&
		SUCCEEDED(builder->AddFontFile(file)) &&
		SUCCEEDED(builder->CreateFontSet(&set)) &&
		SUCCEEDED(e->write->CreateFontCollectionFromFontSet(set, &e->fonts)) &&
		SUCCEEDED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &e->draw)) &&
		SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
			__uuidof(IWICImagingFactory), (void **)&e->images));
	release(set); release(builder); release(file); free(wide);
	if (!ok) { st_close(e); return nullptr; }
	return e;
}
void st_close(St_Engine *e) {
	if (!e) return;
	release(e->images); release(e->draw); release(e->fonts); release(e->write);
	if (e->apartment) CoUninitialize();
	free(e);
}

St_Layout *st_layout(St_Engine *e, const char *text, int length, float size, int weight) {
	if (!e || length < 0 || !isfinite(size) || size <= 0) return nullptr;
	int n = length ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, length, nullptr, 0) : 0;
	if (length && !n) return nullptr;
	WCHAR *wide = (WCHAR *)calloc((size_t)n + 1, sizeof(WCHAR));
	St_Layout *l = (St_Layout *)calloc(1, sizeof(*l));
	if (!wide || !l) { free(wide); free(l); return nullptr; }
	MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, length, wide, n);
	l->engine = e; l->length = length;
	l->text = (char *)calloc((size_t)length + 1, 1);
	if (!l->text) { free(wide); free(l); return nullptr; }
	if (length) memcpy(l->text, text, length);
	WCHAR locale[LOCALE_NAME_MAX_LENGTH] = {};
	GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH);
	IDWriteTextFormat *format = nullptr;
	HRESULT hr = e->write->CreateTextFormat(L"Geist", e->fonts, (DWRITE_FONT_WEIGHT)weight,
		DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, locale, &format);
	if (SUCCEEDED(hr)) {
		format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
		// The layout engine resolves bidi runs. Select the paragraph's natural
		// base direction with the operating system's Unicode classification.
		WORD *types = (WORD *)calloc(n + 1, sizeof(WORD));
		if (types && GetStringTypeW(CT_CTYPE2, wide, n, types)) {
			for (int i = 0; i < n; i++) {
				if (types[i] == C2_RIGHTTOLEFT) { format->SetReadingDirection(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT); break; }
				if (types[i] == C2_LEFTTORIGHT) break;
			}
		}
		free(types);
		hr = e->write->CreateTextLayout(wide, n, format, 1000000, 1000000, &l->value);
	}
	release(format); free(wide);
	if (FAILED(hr)) { st_destroy(l); return nullptr; }
	DWRITE_TEXT_METRICS metrics = {};
	l->value->GetMetrics(&metrics);
	// Tight layout bounds also avoid cancellation error in overhang metrics.
	l->value->SetMaxWidth(fmaxf(1, metrics.widthIncludingTrailingWhitespace));
	l->value->SetMaxHeight(fmaxf(1, metrics.height));
	l->value->GetMetrics(&metrics);
	DWRITE_OVERHANG_METRICS ink = {};
	l->value->GetOverhangMetrics(&ink);
	UINT32 count = 0;
	l->value->GetLineMetrics(nullptr, 0, &count);
	DWRITE_LINE_METRICS *lines = (DWRITE_LINE_METRICS *)calloc(count, sizeof(*lines));
	float baseline = size;
	if (lines && SUCCEEDED(l->value->GetLineMetrics(lines, count, &count)) && count) baseline = lines[0].baseline;
	free(lines);
	l->metrics = {metrics.widthIncludingTrailingWhitespace, metrics.height, baseline,
		{-ink.left, -ink.top, metrics.layoutWidth + ink.left + ink.right, metrics.layoutHeight + ink.top + ink.bottom}};
	return l;
}
void st_destroy(St_Layout *l) {
	if (!l) return;
	release(l->value); free(l->text); free(l);
}
St_Metrics st_metrics(St_Layout *l) { return l->metrics; }

int st_fit(St_Layout *l, float width) {
	if (!isfinite(width) || width < 0) return -1;
	if (l->metrics.width <= width) return l->length;
	IDWriteInlineObject *ellipsis = nullptr;
	if (FAILED(l->engine->write->CreateEllipsisTrimmingSign(l->value, &ellipsis))) return -1;
	DWRITE_INLINE_OBJECT_METRICS em = {};
	ellipsis->GetMetrics(&em);
	if (em.width > width) { release(ellipsis); return -1; }
	float old_width = l->value->GetMaxWidth();
	DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
	l->value->SetTrimming(&trimming, ellipsis);
	l->value->SetMaxWidth(fmaxf(width, 0.001f));
	BOOL trailing, inside;
	DWRITE_HIT_TEST_METRICS hit = {};
	// The trimming sign is the last visual cluster in reading direction.
	bool rtl = l->value->GetReadingDirection() == DWRITE_READING_DIRECTION_RIGHT_TO_LEFT;
	l->value->HitTestPoint(rtl ? 0 : width, l->metrics.baseline / 2, &trailing, &inside, &hit);
	int prefix = st_bytes(l->text, l->length, hit.textPosition);
	trimming.granularity = DWRITE_TRIMMING_GRANULARITY_NONE;
	l->value->SetTrimming(&trimming, nullptr);
	l->value->SetMaxWidth(old_width);
	release(ellipsis);
	return prefix;
}
float st_cursor(St_Layout *l, int index) {
	if (!l->length) return 0;
	FLOAT x = 0, y = 0;
	DWRITE_HIT_TEST_METRICS hit = {};
	if (FAILED(l->value->HitTestTextPosition(st_units(l->text, l->length, index), FALSE, &x, &y, &hit))) return 0;
	return x;
}
int st_hit(St_Layout *l, float x, int nearest) {
	if (!l->length) return 0;
	BOOL trailing = FALSE, inside = FALSE;
	DWRITE_HIT_TEST_METRICS hit = {};
	if (FAILED(l->value->HitTestPoint(x, l->metrics.baseline / 2, &trailing, &inside, &hit))) return 0;
	return st_bytes(l->text, l->length, hit.textPosition + (nearest && trailing ? hit.length : 0));
}
int st_selection(St_Layout *l, int start, int end, St_Rect *rects, int capacity) {
	UINT32 first = st_units(l->text, l->length, start);
	UINT32 length = st_units(l->text, l->length, end) - first;
	UINT32 count = 0;
	l->value->HitTestTextRange(first, length, 0, 0, nullptr, 0, &count);
	DWRITE_HIT_TEST_METRICS *hits = (DWRITE_HIT_TEST_METRICS *)calloc(count, sizeof(*hits));
	if (!hits) return 0;
	if (SUCCEEDED(l->value->HitTestTextRange(first, length, 0, 0, hits, count, &count))) {
		for (UINT32 i = 0; i < count && i < (UINT32)capacity; i++)
			rects[i] = {hits[i].left, hits[i].top, hits[i].width, hits[i].height};
	} else count = 0;
	free(hits);
	return (int)count;
}
St_Image st_render(St_Layout *l, uint8_t r, uint8_t g, uint8_t b) {
	St_Image image = st_image(l->metrics.ink);
	if (!image.pixels) return image;
	IWICBitmap *bitmap = nullptr;
	ID2D1RenderTarget *target = nullptr;
	ID2D1SolidColorBrush *brush = nullptr;
	IWICBitmapLock *lock = nullptr;
	D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,
		D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
	bool ok = SUCCEEDED(l->engine->images->CreateBitmap(image.width, image.height,
		GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &bitmap)) &&
		SUCCEEDED(l->engine->draw->CreateWicBitmapRenderTarget(bitmap, props, &target)) &&
		SUCCEEDED(target->CreateSolidColorBrush(D2D1::ColorF(r/255.f, g/255.f, b/255.f), &brush));
	if (ok) {
		target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
		target->BeginDraw();
		target->Clear(D2D1::ColorF(0.f, 0.f, 0.f, 0.f));
		target->DrawTextLayout(D2D1::Point2F((float)-image.x, (float)-image.y), l->value, brush,
			D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
		ok = SUCCEEDED(target->EndDraw());
	}
	if (ok) {
		WICRect rect = {0, 0, image.width, image.height};
		ok = SUCCEEDED(bitmap->Lock(&rect, WICBitmapLockRead, &lock));
		if (ok) {
			UINT bytes = 0, stride = 0; BYTE *pixels = nullptr;
			ok = SUCCEEDED(lock->GetStride(&stride)) && SUCCEEDED(lock->GetDataPointer(&bytes, &pixels));
			if (ok) for (int y = 0; y < image.height; y++)
				memcpy(image.pixels + y * image.stride, pixels + y * stride, image.stride);
		}
	}
	release(lock); release(brush); release(target); release(bitmap);
	if (!ok) { free(image.pixels); image.pixels = nullptr; }
	return image;
}
