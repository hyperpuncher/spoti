# app icon

`icon.svg` is the shared source. the PNG and ICO outputs are committed.
macOS packaging generates its ICNS from the PNG with native `sips` and
`iconutil`.

regenerate them from the repository root after an SVG change:

```sh
svgo assets/app/icon.svg
rsvg-convert -w 1024 -h 1024 assets/app/icon.svg -o assets/app/icon.png
magick assets/app/icon.png -define icon:auto-resize=256,128,64,48,32,16 assets/app/icon.ico
```

- SDL uses the PNG for the running app.
- Windows embeds the ICO through `packaging/windows/app.rc`.
- macOS builds a multi-size ICNS for the bundle, then signs it.
- Linux uses `app.spoti.desktop` and the `app.spoti` application ID.
