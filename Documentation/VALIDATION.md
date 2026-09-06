# Native rewrite validation

Verified September 5, 2026 on an Apple M1 Max (10 CPU cores, 64 GiB memory), macOS 26.6.2, Xcode 26.6 (17F113), and Swift 6.3.3 in Swift 5 language mode. Application deployment target: macOS 26.0, arm64.

## Automated verification

| Check | Result |
|---|---|
| `./gradlew check dmg` | Passed; 34 Swift core tests across six suites, including parameterized cases |
| `ATLAS_UI_BENCHMARK=1 ./gradlew testUI` | Passed; all seven UI tests, including 10,000/100,000 observations |
| Focused large-map rerun with process-memory sampling | Passed |
| Unchanged `./gradlew buildApp packageDmg` | All five actionable tasks up to date; 489 ms reported by Gradle |
| App and embedded framework architecture | Both arm64 |
| App/framework signatures and bundled catalog | Verified with `Scripts/verify-app.sh` |
| DMG checksum | Verified |
| DMG installation/launch | Mounted read-only, copied app into a temporary Applications folder, verified it, and observed its native window with an offline synthetic capture |
| Standalone runtime | Launch passed with `PATH=/usr/bin:/bin`; executable links only Apple libraries and its bundled Swift core framework |
| Repository whitespace check | `git diff --check` passed |
| Web implementation removal | No TypeScript, JavaScript, HTML, CSS, npm manifests, or MapLibre/Vite application files remain |

Core coverage includes metadata/BOM/quoted/multiline CSVs, invalid rows, manufacturer normalization, explicit timestamp offsets and local timezone interpretation, filters, duplicate session names, built-in/custom/ignored/research rules, grouping and dismissals, all movement sensitivities, accuracy and fixed-anchor behavior, overlapping sessions and minute deduplication, rolling-window expiry and a brute-force oracle, trust digests and privacy labels, cancellation, concurrent settings updates, explicit retry after failed writes, corrupt settings, and full-capacity trust-file save/reload.

The original synthetic morning/evening fixtures and reference expected results remain under `Tests/WardriveAtlasCoreTests/Fixtures`. Reference tests compare the native classifications and movement coverage to the previous engine's outputs.

UI checks cover native CSV import, sample loading, capture filtering, Points/Clusters/Heatmap, live MapKit presentation, grid startup/fallback, evidence selection, clearing pending work, reopening, and Settings. Map-failure recovery invokes the actual MapKit delegate error handler using a Debug-only injection. It does not require changing the Mac's network configuration. Native window screenshots were visually inspected for layout and selection rendering.

Xcode stores UI reports and screenshots in `build/xcode/DerivedData/Logs/Test/`. A focused import/inspector regression also passed with finite RSSI, accuracy, and altitude values larger than the integer range. The complete passing run is `Test-WardriveAtlas-2026.09.05_19-41-02--0400.xcresult`; the measured map rerun is `Test-WardriveAtlas-2026.09.05_19-46-30--0400.xcresult`. These generated reports are removed by `clean`.

## Core workload

Release-mode Swift tests generate CSVs from the synthetic drive, import every row, apply a minimum RSSI of −60 dBm, and analyze/project the resulting filtered records. Timings exclude compilation and synthetic CSV generation. Peak memory is `getrusage` resident high-water usage of the test process, including generated inputs and result objects. The two sizes run serially; these are local samples rather than statistical performance guarantees.

| Imported rows | CSV import | Filtering | Analysis of filtered rows | Map projection | Total | Peak resident memory |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 151 ms | 0.51 ms | 230 ms | 2.9 ms | 384 ms | 52.6 MiB |
| 100,000 | 1,389 ms | 6.54 ms | 2,270 ms | 31.8 ms | 3,698 ms | 383.9 MiB |

Reproduce with:

```sh
ATLAS_BENCHMARK=1 swift test -c release --filter BenchmarkTests
```

## Native map workload

The UI benchmark loads all observations without a signal filter, switches Clusters → Heatmap → Points, and fits the data. It runs each size in grid and street-map modes, then clears it. Timings include XCTest event delivery, built-in waits, accessibility queries, and animations; they are not frame-rate measurements or isolated rendering latency. Apple tile loading and cache state also affect the results.

| Observations | Grid interaction sequence | Street-map interaction sequence | Sampled app peak resident memory |
|---:|---:|---:|---:|
| 10,000 | 5.97 s | 11.36 s | 450.5 MiB |
| 100,000 | 10.57 s | 7.45 s | 1,152.2 MiB |

Process memory was sampled every 0.5 seconds during the Debug UI workload. Each size used a fresh application process. A viewport aggregation pass now bounds MapKit annotation views while preserving all visible counts and all records in analysis. Dense groups separate by category/radio and reveal more detail when zoomed. This avoids the excessive memory and UI-query timeout encountered when giving MapKit 100,000 individual annotations.

Reproduce with:

```sh
ATLAS_UI_BENCHMARK=1 ./gradlew testUI \
  -PuiTest=WardriveAtlasUITests/WardriveAtlasUITests/testLargeCaptureMapInteraction
```

## Distribution artifact

The verified local release is `dist/WardriveAtlas-0.1.0-arm64.dmg`, with its `.sha256` file and `WardriveAtlas-0.1.0-arm64-release.json` manifest. Following the September 6 application icon update, the app bundle is about 6.3 MiB and the DMG about 4.2 MiB. The manifest records the source commit and whether the working tree contains changes.

The new icon's ten PNG representations (16–1024 pixels) retain alpha transparency. Small-size previews were visually checked, and `./gradlew buildApp dmg` rebuilt and verified the signed app and installer. The packaged app's `CFBundleIconName` and `CFBundleIconFile` both select `AtlasAppIcon`.

The app is locally ad-hoc signed. Developer ID signing and optional notarization configuration follow pidex, but those credential-dependent distribution paths were not exercised in this local validation.

For a staged or copied installation, repeat the standalone smoke check with:

```sh
Scripts/verify-app.sh /path/to/WardriveAtlas.app
swift Scripts/smoke-launch.swift /path/to/WardriveAtlas.app
```

The smoke check uses isolated settings, opens an offline synthetic capture, checks for a native window, and terminates that test process. It does not write imported captures or install development tools into the app.
