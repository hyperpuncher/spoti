# fonts

Geist is the required primary face on all three platforms.

- `Geist[wght].ttf`: regular (400) for ordinary text and numbers, medium
  (500) for track titles, and extra bold (800) for headings.
- `OFL.txt`: the SIL Open Font License for the bundled font.

source: https://github.com/vercel/geist-font

`SPOTI_FONTS` overrides the font directory. the app also searches its install
layout and the development checkout. it does not replace system fonts.

## native text

| platform | layout and fallback | rasterization |
| --- | --- | --- |
| Linux | pango 1.56 or newer | Cairo |
| Windows | DirectWrite | Direct2D |
| macOS | CoreText | CoreGraphics |

the platform owns complete strings, including script shaping, bidirectional
runs, installed-font fallback, color emoji, and ellipsis. the editor uses the
same layout for caret positions, hit testing, and visual selection ranges.
font-file parsing and a separate emoji renderer are not needed.

Linux needs installed script and symbol fonts, such as Noto, plus Noto Color
Emoji. other platforms use their installed fonts. coverage depends on those
fonts; an unsupported character can still show a missing-glyph box.

## ownership and caching

native engines and layouts belong to the UI thread. each cached layout owns
its text. SDK headers define the native types behind a small C interface;
no generated binding collection or custom COM vtable is required.

SDL3 receives premultiplied label textures. text foreground is part of the
texture key, so color emoji are not tinted with that foreground. opacity
modulates both RGB and alpha. measurement, drawing, fitting, and editing share
up to 2,048 layouts in Odin's core LRU cache. each layout also retains the
native cut for its last fitted width. evicted entries are released after
presentation. textures use a soft 16 MiB budget; the least recently used
textures are released first. empty space does not need a texture.

headless Linux tests cover scripts, symbols, joined color emoji, grapheme
boundaries, trailing spaces, bidi selection, fitting, texture blending, and
cache ownership. Windows and macOS also run headless text tests in CI;
local Linux checks do not establish native behavior on those platforms.
