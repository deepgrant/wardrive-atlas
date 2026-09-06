# Wardrive Atlas application icon

The current icon combines an amber survey route and cyan radio waves over a blue map. The rounded tile has a transparent surround and scales for Finder, the Dock, and the application switcher.

- Master: `WardriveAtlasIcon-v2.png` (1254 × 1254 pixels, RGBA).
- Standalone Mac icon: `WardriveAtlas-v2.icns`.
- Active asset catalog: `Sources/WardriveAtlasApp/Resources/Assets.xcassets/AtlasAppIcon.appiconset`.
- Preparation: `swift Scripts/prepare-app-icon.swift` regenerates all ten macOS representations, from 16 to 1024 pixels, and the standalone ICNS from the checked-in master. This performs only resizing and packaging, preserving the original transparent artwork. Ordinary builds use the checked-in catalog and require no image-generation tools or network access.
- The earlier procedural `AppIcon` artwork and its generator remain available as an alternate design. `project.yml` selects `AtlasAppIcon`.

Created on 2026-09-06 with the built-in image generation tool. No CLI/API fallback was used.

## Generation prompt

```text
Use case: stylized-concept.
Asset type: production macOS application icon for Wardrive Atlas, a native map-based wireless survey analysis app.
Primary request: create one beautifully finished, distinctive application icon, not a mockup or a presentation sheet.
Subject: a bold warm amber survey route crossing a dark indigo cartographic tile. The route rises through three or four rounded turns, with a small ivory starting dot and a larger ivory destination dot. At the destination, two crisp cyan radio-wave arcs sweep outward, making the route and wireless signal read as one simple emblem.
Style: premium native Mac icon artwork, restrained dimensional materials, softly beveled enamel route, subtle frosted map surface, clean precise edges. Rich midnight blue and indigo match the application's existing palette, with amber and icy cyan accents.
Composition: straight-on square view, centered macOS rounded-square tile approximately 880 pixels wide within a 1024 by 1024 pixel canvas, generous transparent padding around the outside. All meaningful artwork contained inside the tile. Strong simple silhouette and generous spacing so the amber route and radio arcs remain legible at 32 pixels. A few very subtle large cartographic street lines and one flowing river shape form the background; they must be secondary to the emblem.
Lighting: soft studio lighting from upper left, gentle controlled highlights and shallow depth, softly luminous colors without neon glare.
Background: genuinely transparent alpha outside the rounded-square tile, including the corners; no white or checkerboard background. A delicate close shadow beneath the tile is acceptable.
Constraints: one icon only, no letters, no words, no numbers, no compass labels, no watermark, no border around the image, no device mockup, no branding from other apps, no tiny decorative dots, no noisy texture. Render polished finished icon artwork at 1024 by 1024 pixels.
```
