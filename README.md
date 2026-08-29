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

## Run it locally

You need [Node.js 22.12 or newer](https://nodejs.org/). Install the local dependencies once:

```sh
npm install
```

Then start the app:

```sh
npm start
```

Then open the local address shown in the terminal, normally [http://127.0.0.1:4173](http://127.0.0.1:4173). If that port is already occupied, Vite automatically chooses the next available one. Stop the app with `Ctrl+C` in the terminal.

To run the CSV importer tests:

```sh
npm test
```

To run the same strict TypeScript checks used by the reference projects:

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
MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type
```

Rows without valid latitude and longitude values are skipped. Band labels are inferred from the channel number; BLE rows are identified from the `Type` column. Zod schemas validate normalized records at the untrusted CSV boundary before observations enter application state.

## Privacy and offline behavior

Imported files are parsed in browser memory and are never sent to a server. Closing the tab clears the imported data. The app contains no analytics and makes no wardrive-data API requests.

The street map uses the same technology as the MBTA Tracker project: MapLibre GL 5.24 with OpenFreeMap vector tiles and a local visual style. Enabling **Show street map** contacts OpenFreeMap for map tiles, fonts, and sprites, but never sends imported CSV contents. Turn the setting off to use the offline coordinate background without any tile requests. Previously loaded street tiles may remain in the browser cache.

## Project structure

- `index.html` — application structure and accessible controls
- `styles.css` — responsive field-atlas visual design
- `src/csv.ts` — typed CSV parsing, normalization, and Zod schemas
- `src/app.ts` — typed importing, filtering, privacy, and MapLibre visualization
- `map-styles/atlas-map.json` — local MapLibre style using OpenFreeMap vector tiles
- `vite.config.ts` — local-only development and preview server configuration
- `test/csv.test.ts` — focused Vitest importer and schema tests
- `tsconfig.json` — strict compiler rules aligned with MBTATracker and FitForge

## License

Apache-2.0
