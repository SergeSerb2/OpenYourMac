# Artwork and screenshots

`assets/icon.svg` is the repository's editable vector icon source.
`scripts/make-icon.sh` uses `scripts/svg2png.swift` to generate `assets/AppIcon.icns`
and `resources/raycast/images/openyourmac.png`. Run it from the repository root
on macOS with Xcode's Swift tools installed:

```sh
scripts/make-icon.sh
```

The README uses the Configuration and Shortcuts light/dark images in
`docs/images/`. To make replacement app images, use the offscreen `--snapshot`
flow in [manual testing](manual-testing.md#build-and-safe-diagnostics). Review
sample text and display names before publishing any image. Do not use screenshots
of another product or of a personal desktop as project artwork.

`docs/images/minimap.png` is a synthetic strip illustration. Keep it separate
from evidence of real-window behavior. The images show appearance; they do not
establish runtime or platform support.
