# Wardrive Atlas

Wardrive Atlas is a private, local-first viewer for Wi-Fi and Bluetooth survey files captured with devices such as the Biscuit Pro. It reads WiGLE-format CSV exports directly—without a WiGLE account, API, or upload.

## What the MVP can do

- Import one or more CSV session files, including files with a metadata line before the header.
- Correctly read quoted commas, escaped quotes, and multiline quoted values.
- Plot Wi-Fi and BLE observations on a MapLibre map as points, clusters, or a signal heatmap.
- Filter by session, signal type, band, channel, security mode, and minimum RSSI.
- Trace the observation route when timestamps are present.
- Inspect individual observations and switch SSIDs and BSSIDs to private aliases or hide them.
- Pan, zoom, and fit the view to the current data.
- Clear all imported data from the tab at any time.
- Find Flock, Axon, and Meta smart-glasses candidates using a bundled local rule catalog, with optional broader research leads.
- Review Bluetooth addresses repeatedly seen along your drive, with local co-travel evidence and a reversible trusted-device list.

## Run it locally

You need [Node.js 22.12 or newer](https://nodejs.org/). Install the local dependencies once:

```sh
npm install
```

Then start the app with the Gradle wrapper:

```sh
./gradlew appRun
```

On Windows, use `gradlew.bat appRun`. The `run` task is also available as a shorter alias.

You can still start Vite directly when working only on the frontend:

```sh
npm start
```

Then open the local address shown in the terminal, normally [http://127.0.0.1:4173](http://127.0.0.1:4173). If that port is already occupied, Vite automatically chooses the next available one. Stop the app with `Ctrl+C` in the terminal.

To run the CSV importer tests:

```sh
npm test
```

The Gradle wrapper provides the complete project workflow without requiring a separately installed Gradle:

```sh
./gradlew lint      # strict TypeScript checks
./gradlew test      # importer, detection, grouping, and rule-schema tests
./gradlew check     # formatting, linting, and tests
./gradlew build     # checks plus the production Vite bundle
```

Gradle delegates these application tasks to the locked npm toolchain. The wrapper uses Gradle 9.7.1 and pins the official binary-distribution checksum.

To run the strict TypeScript checks directly through npm:

```sh
npm run lint
```

To verify formatting and create a production build:

```sh
npm run format:check
npm run build
```

## CSV format

Wardrive Atlas supports the common Biscuit/WiGLE-style layout. A metadata line is optional. Recognized columns include:

```text
MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,MfgrId,Type
```

Rows without valid latitude and longitude values are skipped. Band labels are inferred from the channel number; BLE rows are identified from the `Type` column. Zod schemas validate normalized records at the untrusted CSV boundary before observations enter application state.

`MfgrId` is optional. Biscuit's hexadecimal Bluetooth company IDs (for example `09C8`, `034D`, or `0x09c8`) are normalized to four uppercase hexadecimal digits. Malformed or missing values become unavailable evidence, without dropping the observation. No decimal conversion or byte swapping is guessed.

## Explore notable detections

Import your CSV normally. **Notable detections** lists candidate observed addresses, with separate category counts for Flock, Axon, and Meta glasses. Select a result or its navy map pin to zoom to its sightings and read **Why it was flagged**. The sample drive contains synthetic examples of all three categories and a research lead.

- Solid navy pins mark default or custom-rule candidates; hollow, dashed pins mark research-only leads. Pins remain visible in Points, Clusters, Heatmap, and offline mode. Category icons distinguish roadside-camera, body-camera, and glasses clues; a plus marks multiple categories.
- One list entry groups the same normalized address and radio type across selected sessions. A pin for each session uses the strongest observed signal, then earliest valid time to break ties. Missing signals use the earliest valid time, or input order when times are also unavailable. Selecting a candidate highlights all its currently filtered observations, including same-address sightings without the original name or manufacturer evidence.
- All ordinary filters also constrain this analysis. Category buttons filter notable pins/list only, leaving the drive visible. Sort by evidence, signal, or recency. Counts are **observed addresses**, not confirmed physical devices; category counts can overlap. Missing or invalid addresses cannot be grouped safely and remain separate observation-level candidates.
- **Include research leads** is off by default. It enables ambiguous community Wi-Fi prefixes and serial-only Bluetooth names. Consumer chipsets can match. An empty result means no matching evidence in this CSV view—not that no cameras were present.
- Pins label **Observed here**, the receiver's position. They are not estimated device locations. A name, company ID, or address prefix does not confirm a camera, its owner, or its installation site. Strong signal is not a calibrated distance measurement.

### Evidence and source limitations

The catalog is versioned `2026-08-30.1`, reviewed August 30, 2026. It is bundled with the application and never downloads updates at runtime. Rule details retain all matching evidence and link to their sources; clicking those links opens an external website.

| Category | Default CSV evidence | Source |
|---|---|---|
| Flock | `B4:1E:52` prefix; Bluetooth company ID `09C8`; Bluetooth names starting `Penguin-` or `Flock-`, or exactly `pigvision` / `FS Ext Battery` (case-insensitive) | [Biscuit Wiki](https://codehedge.github.io/Biscuit-Wiki/3rd-party-integration/wardrive.html) |
| Axon | Bluetooth-only prefix `00:25:DF` or company ID `034D` | [OUI SPY research](https://github.com/colonelpanichacks/oui-spy-unified-blue) |
| Meta glasses | Bluetooth names containing `Ray-Ban`, `Wayfarer`, or `Oakley Meta` (case-insensitive) | [OUI SPY research](https://github.com/colonelpanichacks/oui-spy-unified-blue) |

The optional 32-prefix Wi-Fi research snapshot credits [NitekryDPaul / DeFlockJoplin, maintained in flock-you](https://github.com/colonelpanichacks/flock-you/blob/main/datasets/NitekryDPaul_wifi_ouis.md), using its July 2026 reviewed list. Withdrawn prefixes `F8:A2:D6`, `CC:CC:CC`, `00:0C:E7`, `94:2A:6F`, `F4:E2:C6`, and `6C:CD:D6` are excluded. The explicitly reported locally administered prefix `82:6B:F2` remains an experimental lead, not a vendor allocation. Wi-Fi multicast prefixes are rejected. Bluetooth address type is unavailable in this export; Wi-Fi address-bit rules are not applied to Bluetooth.

Standard CSV exports do **not** retain Biscuit's live notable methods, probe behavior, advertisement payload, or service UUIDs. Atlas does not reconstruct these or claim exact Biscuit parity. In particular, Meta company ID alone is not a default match: the published stronger rule requires a company ID and service UUID in the same advertisement. Rotating addresses may produce multiple entries or defeat prefix matching entirely. Speed-camera classification, live scanning, packet import, and device-location estimation are not part of this release.

### Your own rules

Open **Rules** to add a three-byte prefix, category, and radio type, or ignore a prefix. Custom rules are explicitly labeled user-defined. An ignored prefix overrides built-in and custom matches for its selected radio types, without deleting ordinary observations. **Dismiss candidate for this tab** hides an individual result; **Restore dismissed** brings dismissed results back. Clearing data also clears dismissals.

Custom and ignored prefix rules are saved in browser storage, scoped to the browser and exact local origin (host and port). The movement trusted-device list is saved separately, as described below. Captures, analysis results, research-toggle state, and individual-device dismissals are never automatically saved. Storage failures show a warning while rules continue working in memory.

**Export rules** saves a versioned JSON configuration containing only custom and ignored prefixes. **Import rules** validates and merges it, deduplicating identical entries; invalid, unsupported, oversized files or combined lists above 500 entries per rule type leave current rules unchanged. **Reset custom rules** removes custom and ignored prefixes but leaves built-in signatures active. Rule files are limited to 128 KB. The schema accepts `version: 1`, `custom: [{prefix, category, protocol}]`, and `ignored: [{prefix, protocol}]`, with categories `flock`, `axon`, `meta` and protocols `Both`, `Wi-Fi`, `BLE`.

## Counter-surveillance: seen along your drive

Choose **Counter-surveillance** beside **Notable** in the sidebar. **Candidates** and **Medium** sensitivity are the defaults. Ordinary drive observations stay visible. Try the sample's fictional shared-route companion to explore the feature without a personal capture.

- **Candidates**: Bluetooth addresses whose evidence meets every threshold in one rolling 12-hour window. This means **Co-travel candidate**, never confirmed surveillance or a threat probability. Your vehicle equipment and unrelated people sharing a route can qualify.
- **Observed**: other Bluetooth addresses, including those with insufficient usable time or GPS evidence.
- **Context**: Wi-Fi addresses and Bluetooth Flock/Axon signature matches. Context is not proof of fixed infrastructure; these addresses are not movement candidates. Default and custom camera signatures are considered independently of notable ignored prefixes or dismissals. Research-only signatures do not establish camera context. Meta-name clues do not suppress movement evidence.
- **Trusted**: addresses you explicitly marked as trusted, including saved entries absent from the current captures. Removing trust immediately restores eligibility; ordinary observations and Notable detections never disappear because of trust.

Select a list result (Enter/Space also work) or a diamond-arrow map marker to inspect its observations. Solid navy/amber diamonds indicate movement candidates; hollow diamonds indicate other movement views. The panel separates **whole-selected-range** totals from the **strongest-window** evidence, shows satisfied and unmet thresholds, and includes a signal-history plot and independent-sighting timeline. Signal values are not converted to distance. Map pins use the last independent sighting in each session; addresses without usable evidence remain selectable in the list and ordinary map but have no movement pin.

Selected amber dots highlight filtered observations. Dashed **receiver observation paths** connect eligible independent sightings within a session only, breaking when a gap exceeds five minutes. They are not reconstructed device tracks. The overlay works in Points, Clusters, Heatmap and with street tiles disabled. Existing session, time, RSSI, radio, channel, security and band filters all constrain the analysis. Selected files are assumed to belong to the same recording user.

### Exact calculations

These defaults are inspired by [Biscuit's counter-surveillance guidance](https://codehedge.github.io/Biscuit-Wiki/features/counter-surveillance.html), reviewed August 30, 2026. Atlas implements the following explicit CSV calculations, not Biscuit scoring parity:

| Sensitivity | Independent sightings | Locations | Elapsed time | Travel span |
|---|---:|---:|---:|---:|
| High | 2 | 2 | 5 minutes | 250 m |
| Medium (default) | 3 | 2 | 10 minutes | 500 m |
| Low | 4 | 2 | 20 minutes | 750 m |

1. Group only by the normalized **full address and radio type**. Names, prefixes, RSSI and proximity never link different or rotating addresses. Invalid addresses cannot supply movement evidence.
2. Require a finite timestamp, usable latitude/longitude (not the unset `0,0` fix), and reported accuracy **greater than zero and at most 75 m**. Missing/poor optional evidence never removes an imported observation. Coverage reports one exclusion reason per row, in priority order: address, time, position, accuracy. It also reports minute-level repeats separately. Coverage includes all radios; sidebar sighting/location totals refer to the current result view. Location totals sum per-address locations, not distinct geographic places across all devices.
3. Keep at most one independent sighting per address per clock minute, including overlapping files. Choose the smallest reported accuracy radius, then earliest timestamp, then latitude/longitude order. Exact ties use session name and opaque row ID only for deterministic selection.
4. In chronological order, assign each sighting to the earliest fixed anchor within 200 m, or create a new anchor at that position. Anchors remain fixed across the selected range; no centroids, transitive merges or route-length summation.
5. Evaluate rolling windows of at most 12 hours (endpoints included). Every threshold must hold **in the same window**. Travel span is the maximum pairwise great-circle separation between qualifying receiver positions **minus both reported accuracy radii**, clamped to zero. This is a conservative receiver-position span, not device range or distance traveled.
6. Pick the strongest window by qualification, number of separated locations, independent sightings, travel span, then most recent end time. Full-selected-range observation/session totals are shown separately and do not inflate that window's evidence.

Calculations run in a local Web Worker. Filter changes are briefly debounced; superseded workers are terminated and stale responses discarded. Zod validates sensitivity, trust storage, and worker requests/responses. No live scanning, alerts, uploads, runtime research requests, baseline reconstruction or automatic trust is performed.

CSV re-logging thresholds, rotating addresses, missing baseline rows and export exclusions limit coverage. A CSV cannot recover omitted observations or Biscuit's live tracking state. **Empty results cannot establish that nothing traveled with the recorder.**

### Your trusted-device list

Select an address and choose **Mark as trusted** for equipment you recognize. Use **Trusted** to select it and remove trust, or remove a saved entry even when its capture is no longer loaded. Entries present in loaded captures use the current hide/hash/show settings; absent entries show a digest-based alias (or “Hidden”). Nothing is trusted merely because it appears near the start.

Only `{version: 1, devices: [{digest, type}]}` is saved under the separate `wardrive-atlas.co-travel-trust.v1` storage key. `digest` is the **full 64-hex-character SHA-256** of `wardrive-atlas:co-travel:v1|<radio>|<normalized address>`; `type` is `BLE` or `Wi-Fi`. No names, locations, timestamps, sightings, capture rows or results are stored. Digests are pseudonymous, **not encryption or guaranteed anonymity**. The list is local to this browser and exact origin (scheme, host and port), independent of prefix-rule import/export/reset. It survives clearing captures and page reloads.

Saved trust changes synchronize across open Atlas tabs on the same origin, including when the trust key is deleted or browser storage is cleared. Tabs also refresh trust when activated. Each explicit **trust** or **untrust** operation acquires the same exclusive Web Lock, reads and validates the latest saved list, and changes only that address/radio identity. Concurrent additions are retained; trusting an unrelated address cannot bring back a removed entry. For the same identity, the last serialized explicit operation wins. Duplicate operations are harmless. The 10,000-entry limit is checked against the latest list inside the lock; if full, a new addition is rejected with a warning. Counts, lists, buttons and map overlays refresh without repeating movement calculations; a selected detail stays open only while its result remains in the current view.

If Web Locks are unavailable, acquisition takes more than **five seconds**, or storage cannot be safely read, validated or written, Atlas makes **no unlocked persistent write**. The requested change instead applies in this tab only, with a visible warning and **Tab-only** labels. These per-identity choices remain layered over saved trust after other tabs change the list, but disappear when this page closes or reloads. Another successful save never silently saves an earlier tab-only change. In **Trusted**, use **Save change** to explicitly retry one operation, or explicitly change trust again for that identity. Only a successful explicit operation for that identity clears its tab-only override. The saved count can differ from this tab's effective trusted count, including for tab-only removals. Invalid saved data activates no saved trust entries and is not overwritten; local overrides remain in effect.

Trust-changing controls are temporarily disabled during a save; filters and the map remain usable. **After updating Atlas, reload every existing Atlas tab before changing trust.** Older versions do not participate in the locking protocol and can still overwrite the shared list. No storage migration is required.

Synthetic tests cover threshold boundaries, overlapping imports, stationary jitter, fixed anchors, 12-hour expiry, shuffled rows, protocol/context separation, trust restoration, worker cancellation and identifier-free map properties. Trust tests also cover concurrent tabs, same-identity ordering, stale events, deletion/clearing, listener cleanup, entry-limit contention, lock cancellation/timeouts, storage failures and tab-only overrides that are never silently saved. Personal captures are never included in fixtures.

## Privacy and offline behavior

Imported files are parsed in browser memory and are never sent to a server. Closing the tab clears the imported data. The app contains no analytics and makes no wardrive-data API requests.

SSID/address privacy settings also cover notable and movement lists, details, timelines, trusted entries and accessible labels. Opaque IDs—not names, addresses, hashes or session filenames—are used in map feature properties. The separate local analysis worker receives imported rows in memory; it never sends them over the network. Saved prefix rules and trusted digests are configuration, not saved captures. Hash aliases conceal labels but are not encryption or proof of anonymity; raw rows still exist in this tab's memory while loaded.

The street map uses the same technology as the MBTA Tracker project: MapLibre GL 5.24 with OpenFreeMap vector tiles and a local visual style. Enabling **Show street map** contacts OpenFreeMap for map tiles, fonts, and sprites, but never sends imported CSV contents. Turn the setting off to use the offline coordinate background without any tile requests. Previously loaded street tiles may remain in the browser cache.

## Project structure

- `index.html` — application structure and accessible controls
- `styles.css` — responsive field-atlas visual design
- `src/csv.ts` — typed CSV parsing, normalization, and Zod schemas
- `src/app.ts` — typed importing, filtering, privacy, and MapLibre visualization
- `src/notable-rules.ts` — Zod-validated, versioned signature snapshot and attribution
- `src/notable.ts` — pure local matching, grouping, settings validation, and safe map projections
- `src/notable-ui.ts` / `src/notable-pins.ts` — candidate explorer, rule editor, and locally drawn icon sprites
- `src/co-travel.ts` / `src/co-travel-schema.ts` — pure movement analysis and validated evidence contracts
- `src/co-travel-worker.ts` / `src/co-travel-runner.ts` — local computation, boundary validation, and cancellation
- `src/co-travel-ui.ts` / `src/co-travel-map.ts` — evidence explorer and identifier-free movement overlays
- `src/co-travel-trust.ts` — versioned digest-only trusted-device storage
- `map-styles/atlas-map.json` — local MapLibre style using OpenFreeMap vector tiles
- `vite.config.ts` — local-only development and preview server configuration
- `test/csv.test.ts` — focused Vitest importer and schema tests
- `test/notable.test.ts` — synthetic signature, false-positive, grouping, and settings tests (no personal captures)
- `test/co-travel.test.ts` — synthetic movement, windows, trust, worker and map projection tests
- `tsconfig.json` — strict compiler rules aligned with MBTATracker and FitForge
- `build.gradle` — npm-backed lint, test, build, and local app tasks
- `gradlew` / `gradlew.bat` — pinned Gradle 9.7.1 wrapper launchers

## License

Apache-2.0
