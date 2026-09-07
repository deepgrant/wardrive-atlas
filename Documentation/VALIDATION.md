# Native rewrite validation

Review fixes verified September 7, 2026 on an Apple M1 Max (10 CPU cores, 64 GiB memory), macOS 26.6.2, Xcode 26.6 (17F113), and Swift 6.3.3 in Swift 5 language mode. Application deployment target: macOS 26.0, arm64.

## Automated verification

| Check | Result |
|---|---|
| `./gradlew check` | Passed; 39 core tests across seven suites and 11 hosted app regression tests. The opt-in app benchmark is skipped here and runs separately. |
| Release trust benchmark | Passed; 1,334 assessments with 10,000 saved identities filtered in 0.73 ms, below the 100 ms target |
| UI checks | All ten cases verified, including 10,000/100,000 observations, offline heatmap gestures, independent Settings warnings, and inspector trust. Nine passed in the final full workload run; the corrected inspector test passed in a focused rerun. |
| Large-map workload with process-memory sampling | Passed with 10,000 saved trusted identities, Co-travel, and populated Trusted settings |
| `./gradlew buildApp dmg` | Passed; signed application, DMG, checksum, and release manifest created |
| Unchanged `./gradlew buildApp packageDmg` | All five actionable tasks up to date |
| App and embedded framework architecture | Both arm64 |
| App/framework signatures and bundled catalog | Verified with `Scripts/verify-app.sh` |
| DMG checksum | Verified |
| DMG installation/launch | Mounted read-only, copied app into a temporary Applications folder, verified it, and observed its native window with an offline synthetic capture |
| Standalone runtime | Launch passed with `PATH=/usr/bin:/bin`; executable links only Apple libraries and its bundled Swift core framework |
| Repository whitespace check | `git diff --check` passed |
| Web implementation removal | No TypeScript, JavaScript, HTML, CSS, npm manifests, or MapLibre/Vite application files remain |

Core coverage includes metadata/BOM/quoted/multiline CSVs, invalid rows, manufacturer normalization, explicit timestamp offsets and local timezone interpretation, filters, duplicate session names, built-in/custom/ignored/research rules, grouping and dismissals, all movement sensitivities, accuracy and fixed-anchor behavior, overlapping sessions and minute deduplication, rolling-window expiry and a brute-force oracle, trust digests and privacy labels, cancellation, concurrent settings updates, explicit retry after failed writes, corrupt settings, and full-capacity trust-file save/reload. New regressions cover T/space separators, positive/negative/colonless offsets, fractional seconds, independent rules/trust failures, partial retries, simultaneous corrupt files, capacity-warning lifetime, and every evidence-ranking tie-breaker.

Hosted app tests use isolated settings, offline startup, and controlled task completions. They exercise stale selections after filtering, reanalysis, session removal, clearing, and out-of-order analysis/projection; current observation and movement selections; pending trust additions/removals; repeated zooming; invalid rectangles and projected points; geographic heatmap placement; and stale-frame rejection. Race tests use continuations rather than timing sleeps.

The original synthetic morning/evening fixtures and reference expected results remain under `Tests/WardriveAtlasCoreTests/Fixtures`. Reference tests compare the native classifications and movement coverage to the previous engine's outputs.

UI checks cover native CSV import, sample loading, capture filtering, Points/Clusters/Heatmap, live MapKit presentation, grid startup/fallback, evidence selection, clearing pending work, reopening, and Settings. The movement inspector test verifies the saved digest against the selected synthetic address. Map-failure recovery invokes the actual MapKit delegate error handler using a Debug-only injection. It does not require changing the Mac's network configuration. Offline heatmap screenshots before/after pan and zoom were visually inspected: density follows the observation markers at their geographic positions.

Xcode stores reports and screenshots in `build/xcode/DerivedData/Logs/Test/`. The app tests are in `Test-WardriveAtlas-2026.09.07_09-48-09--0400.xcresult`; the full UI workload is in `Test-WardriveAtlas-2026.09.07_09-48-21--0400.xcresult`. That UI run found an incorrect test selector for a combined button label; the corrected inspector check passed in `Test-WardriveAtlas-2026.09.07_09-52-24--0400.xcresult`. The measured map/memory run is `Test-WardriveAtlas-2026.09.07_09-43-31--0400.xcresult`. Generated reports are removed by `clean`.

## Core workload

Release-mode Swift tests generate CSVs from the synthetic drive, import every row, apply a minimum RSSI of −60 dBm, and analyze/project the resulting filtered records. Analysis includes the one-time trusted-identity calculation now moved out of view evaluation. Timings exclude compilation and synthetic CSV generation. Peak memory is `getrusage` resident high-water usage of the test process, including generated inputs and result objects. The two sizes run serially; these are local samples rather than statistical performance guarantees.

| Imported rows | CSV import | Filtering | Analysis of filtered rows | Map projection | Total | Peak resident memory |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 144 ms | 0.39 ms | 361 ms | 2.8 ms | 508 ms | 53.5 MiB |
| 100,000 | 1,362 ms | 5.49 ms | 3,517 ms | 31.1 ms | 4,915 ms | 392.3 MiB |

Reproduce with:

```sh
ATLAS_BENCHMARK=1 swift test -c release --filter BenchmarkTests
```

## Native map workload

The UI benchmark loads all observations without a signal filter and 10,000 synthetic saved trusted identities, opens Co-travel, switches Clusters → Heatmap → Points, and fits the data. It runs each size in grid and street-map modes, opens the populated Trusted settings tab, then clears the captures. Timings include XCTest event delivery, built-in waits, accessibility queries, and animations; they are not frame-rate measurements or isolated rendering latency. Apple tile loading and cache state also affect the results.

| Observations | Open Co-travel | Grid sequence | Street-map sequence | Open Trusted settings | Sampled app peak memory |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 3.25 s | 5.70 s | 8.98 s | 5.27 s | 658.9 MiB |
| 100,000 | 5.53 s | 9.30 s | 8.52 s | 3.35 s | 1,453.1 MiB |

Process memory was sampled approximately every 0.5 seconds during the Debug UI workload. Each size used a fresh application process. A viewport aggregation pass bounds MapKit annotation views while preserving all visible counts and all records in analysis. Dense groups separate by category/radio and reveal more detail when zoomed. The earlier September 5 measurements did not include populated trusted settings or the Co-travel interaction, so those memory figures are not directly comparable.

Reproduce with:

```sh
ATLAS_UI_BENCHMARK=1 ./gradlew testUI \
  -PuiTest=WardriveAtlasUITests/WardriveAtlasUITests/testLargeCaptureMapInteraction
```

## Trust-filter workload

Release hosted tests measure the coordinator's actual movement filtering after analysis and trust settings have been prepared. Every run consumes the result count. Timings exclude that preparation and include Xcode test coverage instrumentation. Pending additions and removals are checked separately against the uncached calculation. No machine-dependent timing assertion is imposed on CI.

| Assessments | Observations | No saved trust | 1,000 saved | 10,000 saved |
|---:|---:|---:|---:|---:|
| 1,334 | 2,000 | 0.47 ms | 0.63 ms | 0.73 ms |
| 6,667 | 10,000 | 2.95 ms | 3.43 ms | 3.69 ms |
| 66,667 | 100,000 | 30.15 ms | 34.74 ms | 37.48 ms |

The reviewed 1,334-assessment/10,000-entry case meets the under-100-ms target on this Mac. Reproduce with:

```sh
ATLAS_TRUST_BENCHMARK=1 ./gradlew testApp \
  -PappTestConfiguration=Release \
  -PappTest=WardriveAtlasAppTests/AppCoordinatorTests/testTrustPerformance
```

## Distribution artifact

The verified local release is `dist/WardriveAtlas-0.1.0-arm64.dmg`, with its `.sha256` file and `WardriveAtlas-0.1.0-arm64-release.json` manifest. The app bundle occupies about 6.4 MiB and the DMG about 4.1 MiB. The manifest records the source commit and the uncommitted working-tree changes. Both the staged app and the copy installed from the DMG passed signature/architecture verification; the installed copy opened its native window with only system tools on its runtime PATH. No XCTest bundles or test-framework dependencies are packaged.

The new icon's ten PNG representations (16–1024 pixels) retain alpha transparency. Small-size previews were visually checked, and `./gradlew buildApp dmg` rebuilt and verified the signed app and installer. The packaged app's `CFBundleIconName` and `CFBundleIconFile` both select `AtlasAppIcon`.

The app is locally ad-hoc signed. Developer ID signing and optional notarization configuration follow pidex, but those credential-dependent distribution paths were not exercised in this local validation.

For a staged or copied installation, repeat the standalone smoke check with:

```sh
Scripts/verify-app.sh /path/to/WardriveAtlas.app
swift Scripts/smoke-launch.swift /path/to/WardriveAtlas.app
```

The smoke check uses isolated settings, opens an offline synthetic capture, checks for a native window, and terminates that test process. It does not write imported captures or install development tools into the app.
