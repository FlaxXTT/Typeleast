# Application icon

The icon uses one vector drawing for the packaged ICNS, the runtime Dock image,
the sidebar, and onboarding. `AppIconArtwork.swift` is the source of truth.
Small icons render from vectors at their own resolution.

## Geometry and colour

- Canvas: 1024 × 1024, transparent outside the enclosure.
- Enclosure: 824 × 824, centred at (512, 512).
- Enclosure curve: the continuous Bézier outline from Apple's Illustrator
  **App Icon Template**, downloaded from [Apple Design Resources](https://developer.apple.com/design/resources/)
  on 17 November 2026 (`iOS-27-Icon-Templates-Photoshop-Illustrator.dmg`).
  The template's 1024-unit outline is scaled into the requested 824-unit tile
  for the application's existing macOS 14+ ICNS format. It is not a circular
  rounded rectangle. The template package itself is not redistributed here.
- Background: sRGB `#FAFAF9`.
- Light: radial white at 5% opacity, from above-left; no linear gradient.
- Edge: 1 design-pixel inner stroke, `#111111` at 6% opacity.
- Bars, left to right: heights `0.30 / 0.58 / 1.00 / 0.72 / 0.42` of 672px,
  each 112px wide with 30px spacing; centred vertically and horizontally.
  The waveform occupies 680 × 672px (about 82% of the tile), leaving
  72px horizontally and 76px vertically inside the enclosure.
- First four bars: `#1D1A1A`; rightmost bar: `#1F5DF2`.
- No baked-in shadow. The artwork keeps the same palette in both app themes.

The enclosure is the application-icon exception to the main interface's
99px circular corner rule.

## Recreate the assets

From `apps/macos`, choose an output folder and run:

```sh
mkdir -p build/icon-artwork
swiftc Sources/AppIconArtwork.swift scripts/make-icon.swift \
  -o build/icon-artwork/make-icon
build/icon-artwork/make-icon build/icon-artwork/AppIcon.iconset Resources/BrandIcon.png
iconutil -c icns build/icon-artwork/AppIcon.iconset -o Resources/AppIcon.icns
```

This creates artwork only. It does not build, install, launch or sign the app.
