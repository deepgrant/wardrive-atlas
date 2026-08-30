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

Only custom and ignored prefix rules are saved in browser storage, scoped to the browser and exact local origin (host and port). Captures, analysis results, research-toggle state, and individual-device dismissals are never automatically saved. Storage failures show a warning while rules continue working in memory.

**Export rules** saves a versioned JSON configuration containing only custom and ignored prefixes. **Import rules** validates and merges it, deduplicating identical entries; invalid, unsupported, oversized files or combined lists above 500 entries per rule type leave current rules unchanged. **Reset custom rules** removes custom and ignored prefixes but leaves built-in signatures active. Rule files are limited to 128 KB. The schema accepts `version: 1`, `custom: [{prefix, category, protocol}]`, and `ignored: [{prefix, protocol}]`, with categories `flock`, `axon`, `meta` and protocols `Both`, `Wi-Fi`, `BLE`.

## Privacy and offline behavior

Imported files are parsed in browser memory and are never sent to a server. Closing the tab clears the imported data. The app contains no analytics and makes no wardrive-data API requests.

SSID/address privacy settings also cover candidate lists, details, and accessible labels. Opaque IDs—not names or addresses—are sent to the local map worker. Saved prefix rules are your configuration, not saved captures. Hash aliases conceal labels but are not encryption or proof of anonymity; raw rows still exist in this tab's memory while loaded.

The street map uses the same technology as the MBTA Tracker project: MapLibre GL 5.24 with OpenFreeMap vector tiles and a local visual style. Enabling **Show street map** contacts OpenFreeMap for map tiles, fonts, and sprites, but never sends imported CSV contents. Turn the setting off to use the offline coordinate background without any tile requests. Previously loaded street tiles may remain in the browser cache.

## Project structure

- `index.html` — application structure and accessible controls
- `styles.css` — responsive field-atlas visual design
- `src/csv.ts` — typed CSV parsing, normalization, and Zod schemas
- `src/app.ts` — typed importing, filtering, privacy, and MapLibre visualization
- `src/notable-rules.ts` — Zod-validated, versioned signature snapshot and attribution
- `src/notable.ts` — pure local matching, grouping, settings validation, and safe map projections
- `src/notable-ui.ts` / `src/notable-pins.ts` — candidate explorer, rule editor, and locally drawn icon sprites
- `map-styles/atlas-map.json` — local MapLibre style using OpenFreeMap vector tiles
- `vite.config.ts` — local-only development and preview server configuration
- `test/csv.test.ts` — focused Vitest importer and schema tests
- `test/notable.test.ts` — synthetic signature, false-positive, grouping, and settings tests (no personal captures)
- `tsconfig.json` — strict compiler rules aligned with MBTATracker and FitForge
- `build.gradle` — npm-backed lint, test, build, and local app tasks
- `gradlew` / `gradlew.bat` — pinned Gradle 9.7.1 wrapper launchers

## License

Apache-2.0
