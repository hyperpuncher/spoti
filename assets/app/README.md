# app icon

`icon.svg` is the shared source. the PNG, ICO, and ICNS outputs are
committed, so builds need no SVG renderer or icon converter.

regenerate them from the repository root after an SVG change:

```sh
svgo assets/app/icon.svg
rsvg-convert -w 1024 -h 1024 assets/app/icon.svg -o assets/app/icon.png
magick assets/app/icon.png -define icon:auto-resize=256,128,64,48,32,16 assets/app/icon.ico
mkdir -p /tmp/spoti-icon-sizes
for size in 16 32 48 128 256 512 1024; do
	magick assets/app/icon.png -resize "${size}x${size}" "PNG32:/tmp/spoti-icon-sizes/${size}.png"
done
png2icns assets/app/icon.icns /tmp/spoti-icon-sizes/*.png
```

- SDL uses the PNG for the running app.
- Windows embeds the ICO through `packaging/windows/app.rc`.
- macOS copies the multi-size ICNS into the bundle, then signs it.
- Linux uses `app.spoti.desktop` and the `app.spoti` application ID.
