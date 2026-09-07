# Native implementation

`WardriveAtlasCore` is a Foundation/CryptoKit Swift library. `WardriveAtlasApp` owns SwiftUI views, AppKit file panels, MapKit rendering, and Swift Charts. Xcode builds the core as an embedded framework; Swift Package Manager builds the same sources for tests. There are no third-party packages or JavaScript runtime components.

## Capture and analysis flow

1. The application coordinator reads selected CSV files in a detached task. The parser handles metadata, quoted fields, timestamps, normalization, and row validation. Captures receive unique session names and opaque observation IDs.
2. Filter changes cancel the preceding analysis and debounce for 120 ms. Filtering, notable classification, independent-sighting selection, and rolling-window movement analysis execute outside the main actor. Generation counters reject completed work that has been superseded.
3. A separate background projection produces `MapPresentation`: opaque IDs, coordinates, radio/color categories, signal weights, selection flags, and paths. Names, raw addresses, trust digests, timestamps, and evidence details are excluded. The coordinator publishes the presentation and its private selection lookup together. Annotations and click handlers retain `MapSelectionToken(presentationID, featureID)` for the data they display. Starting analysis or projection invalidates the accepted presentation ID immediately, so late callbacks cannot select a different result when feature IDs are reused.
4. Clearing captures cancels imports, analysis, and map projection and invalidates their generations. It clears selections and dismissals. Removing a session also removes dismissals for identities no longer loaded.

CSV parsing and analysis loops check cancellation periodically. Movement deduplicates to one sighting per minute, bounding a 12-hour evidence window to at most 721 sightings. Fixed 200 m anchors use spatial cells; rolling maximum-distance bookkeeping avoids recomputing every pair in every window. One window-ranking helper orders qualification, locations, sighting count, travel span, and latest timestamp. Window scanning passes the count directly and only allocates the winning window's sighting IDs. This preserves the original thresholds and independent-sighting tie-breakers.

Analysis computes each movement assessment's trusted identity once alongside its immutable representative. The coordinator rebuilds its effective trust set and sorted Settings rows when saved entries or pending overrides change, and rebuilds the present-identity set when movement analysis changes. Filtering and movement inspector controls reuse those values. The Trusted settings view creates rows lazily.

## Native maps

`NativeMapView` embeds `MKMapView` using `NSViewRepresentable`. Ordinary Points use a custom point overlay to avoid creating one view per observation. Clusters use MapKit annotations and native clustering. For dense datasets, a background viewport pass groups observations into at most 400 cells per radio/category before handing them to MapKit; counts preserve all visible members, and selecting a group zooms into its bounds. Notable and movement markers are grouped separately by category and remain visible in every map mode. This bounds the number of native annotation views at 100,000 rows. Receiver routes use polylines; selected movement paths break by capture and five-minute gaps.

Heatmap calculation accumulates RSSI weights into a 256 × 256 grid and applies a separable Gaussian blur in a cancellable background task. Viewport and projected sample coordinates must be finite; pixel bounds are checked before integer conversion. MapKit displays the image at its geographic rectangle with a custom overlay renderer. The offline view retains a `HeatmapFrame` containing the image, geographic rectangle, and presentation ID. Its geographic extent follows pan and zoom while a replacement is calculated. Data changes clear old frames, and generation checks reject late results. This density visualization is not a device-location estimate or a calibrated distance measurement.

Disabling street maps removes `MKMapView` and displays `OfflineMapView`, an interactive SwiftUI Canvas with coordinate labels, pan/zoom, point selection, grid-bin clusters, and the same heatmap calculation. It uses MapKit's coordinate mathematics but creates no map view or tile requests. Existing online requests may finish after switching views. Apple Maps tile caches are never treated as an offline street-map product.

Offline fit, pan, and zoom share `MapViewport.constrained`: dimensions range from 256 MapKit map points to the world bounds, with the origin kept inside those bounds. Invalid rectangles fall back to the world rectangle.

The main survey uses a SwiftUI Window scene and native Settings. An AppKit delegate routes launch/reopen events through the explicit Show Wardrive Atlas command so an empty restored window set does not leave the app without its survey window.

## Rules and trust

The checked-in JSON catalog preserves version `2026-08-30.1`, explanations, and attribution. Compatible version-1 custom/ignored-prefix imports remain supported. The original synthetic CSV fixtures and expected JavaScript-engine results were preserved as Swift test resources before the web sources were removed.

One `SettingsStore` actor serializes atomic writes in the application's Application Support directory. It owns both rules and trusted identity settings. Capture observations and analysis are never written there. The trusted-identity digest remains SHA-256 of `wardrive-atlas:co-travel:v1|<radio>|<normalized address>`.

Trust updates read the latest saved file and apply only the requested identity. Failed writes add a per-identity session-only override; unrelated successful changes cannot accidentally save pending overrides. Explicit retry is required. Rules have a separate pending-change state requiring save or discard before another edit. Invalid trusted files are preserved, and full-capacity files are tested through save/reload.

Rules and trust retain separate issue state. Session-only warnings derive from pending changes; unreadable-file and capacity warnings remain until those conditions are resolved. The sidebar displays all active warnings in rules-then-trust order, and each Settings tab shows its domain's warnings. No warning strings or issue state are added to the saved JSON formats.

Browser storage is not migrated. The native trusted store starts empty, while exported custom-rule files can be imported.

## Build and distribution

The Gradle 9.7.1 wrapper is retained. The native task graph follows pidex: generate the Xcode project when its layout/configuration changes, skip external package resolution, retain compilation data, stage the app, verify its architecture/resources/signatures, and package the verified app in a DMG. The generated project and shared scheme are checked in.

`check` runs SwiftPM core tests and hosted `WardriveAtlasAppTests` through `testApp`. The shared test scheme starts the unit-test host offline with temporary settings; UI tests explicitly start a separate application with their own isolated directory. Coordinator initializers accept a settings service and analysis/projection operations. Tests hold and release those operations through continuations, including cancelled work, to verify ordering without sleeps.

Local builds sign the app and embedded core framework ad hoc with hardened runtime disabled. Developer ID builds enable hardened runtime, require a matching Team ID, and optionally notarize the DMG using pidex's environment configuration. No task publishes a release.
