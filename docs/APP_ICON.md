# Application icon

The icon uses one vector drawing for the packaged ICNS, the runtime Dock image,
the sidebar, and onboarding. `AppIconArtwork.swift` is the source of truth.
Small icons render from vectors at their own resolution.

## Geometry and colour

- System canvas: 1024 × 1024, with an 824 × 824 enclosure centred at (512, 512).
- Interface canvas: the enclosure fills the square control bounds, with no extra transparent margin.
  Sidebar, onboarding, website marks, favicons and the shared ICO use this framing.
- Enclosure curve: the continuous Bézier outline from Apple's Illustrator
  **App Icon Template**, downloaded from [Apple Design Resources](https://developer.apple.com/design/resources/)
  on 17 November 2026 (`iOS-27-Icon-Templates-Photoshop-Illustrator.dmg`).
  The template's 1024-unit outline is scaled into the requested 824-unit tile
  for the application's existing macOS 14+ ICNS format. It is not a circular
  rounded rectangle. The template package itself is not redistributed here.
- Background: sRGB `#FAFAF9`.
- Light: radial white at 5% opacity, from above-left; no linear gradient.
- Edge: 1 design-pixel inner stroke, `#111111` at 6% opacity.
- Bars, left to right: heights `0.30 / 0.58 / 1.00 / 0.72 / 0.42` of 509.232px,
  each approximately 83.87px wide with 26.96px spacing. The waveform is centred
  and occupies approximately 527.20 × 509.23px. `waveformOccupancy` sets the bar
  dimensions, and `barGapScale` scales the gaps independently.
- First four bars: `#1D1A1A`; rightmost bar: `#1F5DF2`.
- No baked-in shadow. The artwork keeps the same palette in both app themes.

The same `waveformOccupancy = 0.618` controls both framings. The app icon keeps
its official continuous enclosure independently of the interface's 6–20px control/card corners.

## Recreate the assets

From `apps/macos`, choose an output folder and run:

```sh
mkdir -p build/icon-artwork
swiftc Sources/AppIconArtwork.swift scripts/make-icon.swift \
  -o build/icon-artwork/make-icon
build/icon-artwork/make-icon build/icon-artwork/AppIcon.iconset Resources/BrandIcon.png ../..
iconutil -c icns build/icon-artwork/AppIcon.iconset -o Resources/AppIcon.icns
```

The generator also updates `docs/media/icon-256.png`, both website favicon files,
and the Windows icon resource from the edge-to-edge framing.

This creates artwork only. It does not build, install, launch or sign the app.
