import maplibregl, { type GeoJSONSource, type StyleSpecification } from 'maplibre-gl';
import type { FeatureCollection, LineString, Point } from 'geojson';
import { z } from 'zod';
import 'maplibre-gl/dist/maplibre-gl.css';
import { parseWardriveCsv, WardriveRecordSchema, type WardriveRecord } from './csv';
import { normalizeAddress } from './notable';
import { NotableExplorer, NOTABLE_PINS } from './notable-ui';
import { CoTravelExplorer, MOVEMENT_PINS } from './co-travel-ui';
import { identityDigest } from './co-travel-trust';

function requiredElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Required element #${id} was not found.`);
  return element as T;
}

const elements = {
  fileInput: requiredElement<HTMLInputElement>('fileInput'),
  dropZone: requiredElement<HTMLElement>('dropZone'),
  addFilesButton: requiredElement<HTMLButtonElement>('addFilesButton'),
  emptyAddButton: requiredElement<HTMLButtonElement>('emptyAddButton'),
  emptySampleButton: requiredElement<HTMLButtonElement>('emptySampleButton'),
  loadSample: requiredElement<HTMLButtonElement>('loadSample'),
  emptyState: requiredElement<HTMLElement>('emptyState'),
  filterPanel: requiredElement<HTMLElement>('filterPanel'),
  sessionsPanel: requiredElement<HTMLElement>('sessionsPanel'),
  sessionFilter: requiredElement<HTMLElement>('sessionFilter'),
  sessionSummary: requiredElement<HTMLElement>('sessionSummary'),
  typeFilter: requiredElement<HTMLSelectElement>('typeFilter'),
  bandFilter: requiredElement<HTMLSelectElement>('bandFilter'),
  securityFilter: requiredElement<HTMLSelectElement>('securityFilter'),
  channelFilter: requiredElement<HTMLSelectElement>('channelFilter'),
  timeFrom: requiredElement<HTMLInputElement>('timeFrom'),
  timeTo: requiredElement<HTMLInputElement>('timeTo'),
  rssiFilter: requiredElement<HTMLInputElement>('rssiFilter'),
  rssiOutput: requiredElement<HTMLOutputElement>('rssiOutput'),
  routeToggle: requiredElement<HTMLInputElement>('routeToggle'),
  basemapToggle: requiredElement<HTMLInputElement>('basemapToggle'),
  resetFilters: requiredElement<HTMLButtonElement>('resetFilters'),
  clearAll: requiredElement<HTMLButtonElement>('clearAll'),
  statsStrip: requiredElement<HTMLElement>('statsStrip'),
  visibleCount: requiredElement<HTMLElement>('visibleCount'),
  wifiCount: requiredElement<HTMLElement>('wifiCount'),
  bleCount: requiredElement<HTMLElement>('bleCount'),
  strongestRssi: requiredElement<HTMLElement>('strongestRssi'),
  viewSwitcher: requiredElement<HTMLElement>('viewSwitcher'),
  legend: requiredElement<HTMLElement>('legend'),
  fitMap: requiredElement<HTMLButtonElement>('fitMap'),
  detailCard: requiredElement<HTMLElement>('detailCard'),
  closeDetail: requiredElement<HTMLButtonElement>('closeDetail'),
  detailType: requiredElement<HTMLElement>('detailType'),
  detailName: requiredElement<HTMLElement>('detailName'),
  detailList: requiredElement<HTMLDListElement>('detailList'),
  privacyButton: requiredElement<HTMLButtonElement>('privacyButton'),
  privacyDialog: requiredElement<HTMLDialogElement>('privacyDialog'),
  coordinateReadout: requiredElement<HTMLElement>('coordinateReadout'),
  mapDataStatus: requiredElement<HTMLElement>('mapDataStatus'),
  toast: requiredElement<HTMLElement>('toast'),
};

const MAP_STYLE = './map-styles/atlas-map.json';
const SOURCE_POINTS = 'wardrive-points';
const SOURCE_CLUSTERS = 'wardrive-clusters';
const SOURCE_ROUTE = 'wardrive-route';
const SOURCE_GRID = 'offline-grid';
const LAYER_HEATMAP = 'signal-heatmap';
const LAYER_ROUTE_CASING = 'drive-route-casing';
const LAYER_ROUTE = 'drive-route';
const LAYER_POINTS = 'observation-points';
const LAYER_CLUSTER_CIRCLES = 'cluster-circles';
const LAYER_CLUSTER_COUNT = 'cluster-count';
const LAYER_CLUSTER_POINTS = 'cluster-points';

const PrivacyModeSchema = z.enum(['show', 'hash', 'hide']);
const ViewModeSchema = z.enum(['points', 'clusters', 'heatmap']);
const PrivacySettingsSchema = z.object({
  ssid: PrivacyModeSchema,
  bssid: PrivacyModeSchema,
});

type ViewMode = z.infer<typeof ViewModeSchema>;
type PreparedRecord = WardriveRecord & { ssidHash: string; bssidHash: string; identityDigest: string | null };

interface AppState {
  records: PreparedRecord[];
  filtered: PreparedRecord[];
  recordsById: Map<string, PreparedRecord>;
  view: ViewMode;
  sessions: Set<string>;
  privacy: z.infer<typeof PrivacySettingsSchema>;
  route: boolean;
  basemap: boolean;
  mapReady: boolean;
  pendingFit: WardriveRecord[] | null;
  selected: PreparedRecord | null;
  sampleLoaded: boolean;
  mapErrorShown: boolean;
}

const state: AppState = {
  records: [],
  filtered: [],
  recordsById: new Map<string, PreparedRecord>(),
  view: 'points',
  sessions: new Set<string>(),
  privacy: { ssid: 'show', bssid: 'show' },
  route: false,
  basemap: true,
  mapReady: false,
  pendingFit: null,
  selected: null,
  sampleLoaded: false,
  mapErrorShown: false,
};

let toastTimer: ReturnType<typeof setTimeout> | undefined;

function showToast(message: string): void {
  elements.toast.textContent = message;
  elements.toast.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => elements.toast.classList.remove('visible'), 2600);
}

function offlineStyle(): StyleSpecification {
  return {
    version: 8,
    name: 'Wardrive Atlas Offline',
    sources: {},
    layers: [{ id: 'offline-background', type: 'background', paint: { 'background-color': '#dbe6e1' } }],
  };
}

function initializeMap(): maplibregl.Map {
  const map = new maplibregl.Map({
    container: 'mapCanvas',
    style: MAP_STYLE,
    center: [-71.25, 42.4],
    zoom: 8,
    attributionControl: false,
  });

  map.addControl(new maplibregl.NavigationControl({ showCompass: true }), 'top-right');
  map.addControl(new maplibregl.AttributionControl({ compact: true }), 'bottom-right');

  map.on('style.load', () => {
    state.mapReady = true;
    addMapLayers();
    syncMapData();
    if (state.pendingFit?.length) {
      const records = state.pendingFit;
      state.pendingFit = null;
      fitToRecords(records);
    }
  });

  map.on('mousemove', (event) => {
    elements.coordinateReadout.textContent = `${Math.abs(event.lngLat.lat).toFixed(5)}°${event.lngLat.lat < 0 ? 'S' : 'N'}  ${Math.abs(event.lngLat.lng).toFixed(5)}°${event.lngLat.lng < 0 ? 'W' : 'E'} · ${state.basemap ? 'OpenFreeMap' : 'offline'}`;
    const layers = [MOVEMENT_PINS, NOTABLE_PINS, LAYER_POINTS, LAYER_CLUSTER_POINTS, LAYER_CLUSTER_CIRCLES].filter(
      (id) => map.getLayer(id),
    );
    const features = layers.length ? map.queryRenderedFeatures(event.point, { layers }) : [];
    map.getCanvas().style.cursor = features.length ? 'pointer' : '';
  });

  map.on('mouseout', () => {
    elements.coordinateReadout.textContent = state.basemap
      ? 'Street map · OpenFreeMap tiles'
      : 'Offline background · no tile requests';
    map.getCanvas().style.cursor = '';
  });

  map.on('click', (event) => {
    if (movementExplorer.handleMapClick(event.point) || notableExplorer.handleMapClick(event.point)) return;
    const pointLayers = [LAYER_POINTS, LAYER_CLUSTER_POINTS].filter((id) => map.getLayer(id));
    const pointFeature = pointLayers.length ? map.queryRenderedFeatures(event.point, { layers: pointLayers })[0] : null;
    const recordId = pointFeature?.properties?.['recordId'];
    if (typeof recordId === 'string') {
      const record = state.recordsById.get(recordId);
      if (record) showDetail(record);
      return;
    }

    if (!map.getLayer(LAYER_CLUSTER_CIRCLES)) return;
    const cluster = map.queryRenderedFeatures(event.point, { layers: [LAYER_CLUSTER_CIRCLES] })[0];
    const source = map.getSource(SOURCE_CLUSTERS) as GeoJSONSource | undefined;
    const clusterId = cluster?.properties?.['cluster_id'];
    if (!cluster || !source || typeof clusterId !== 'number' || cluster.geometry.type !== 'Point') return;
    const center = cluster.geometry.coordinates as [number, number];
    void source.getClusterExpansionZoom(clusterId).then((zoom) => {
      map.easeTo({ center, zoom });
    });
  });

  map.on('moveend', () => {
    if (!state.basemap) updateOfflineGrid();
  });

  map.on('error', () => {
    if (!state.basemap || state.mapErrorShown) return;
    state.mapErrorShown = true;
    elements.mapDataStatus.textContent = 'Street tiles unavailable · data remains local';
  });

  return map;
}

function addMapLayers() {
  if (!state.mapReady) return;

  if (!state.basemap) {
    atlasMap.addSource(SOURCE_GRID, { type: 'geojson', data: makeOfflineGrid() });
    atlasMap.addLayer({
      id: 'offline-grid-lines',
      type: 'line',
      source: SOURCE_GRID,
      paint: { 'line-color': 'rgba(54, 91, 94, .18)', 'line-width': 1 },
    });
  }

  atlasMap.addSource(SOURCE_ROUTE, { type: 'geojson', data: emptyFeatureCollection() });
  atlasMap.addLayer({
    id: LAYER_ROUTE_CASING,
    type: 'line',
    source: SOURCE_ROUTE,
    layout: { 'line-join': 'round', 'line-cap': 'round', visibility: state.route ? 'visible' : 'none' },
    paint: {
      'line-color': '#172a46',
      'line-width': ['interpolate', ['linear'], ['zoom'], 7, 3.5, 15, 6],
      'line-opacity': 0.82,
    },
  });
  atlasMap.addLayer({
    id: LAYER_ROUTE,
    type: 'line',
    source: SOURCE_ROUTE,
    layout: { 'line-join': 'round', 'line-cap': 'round', visibility: state.route ? 'visible' : 'none' },
    paint: {
      'line-color': '#ffb000',
      'line-width': ['interpolate', ['linear'], ['zoom'], 7, 1.7, 15, 3.2],
      'line-opacity': 1,
      'line-dasharray': [2, 2],
    },
  });

  atlasMap.addSource(SOURCE_POINTS, { type: 'geojson', data: emptyFeatureCollection() });
  atlasMap.addLayer({
    id: LAYER_HEATMAP,
    type: 'heatmap',
    source: SOURCE_POINTS,
    maxzoom: 18,
    paint: {
      'heatmap-weight': ['interpolate', ['linear'], ['get', 'rssi'], -127, 0.05, -20, 1],
      'heatmap-intensity': ['interpolate', ['linear'], ['zoom'], 5, 0.5, 15, 1.8],
      'heatmap-radius': ['interpolate', ['linear'], ['zoom'], 5, 5, 15, 28],
      'heatmap-opacity': 0.82,
      'heatmap-color': [
        'interpolate',
        ['linear'],
        ['heatmap-density'],
        0,
        'rgba(107,63,212,0)',
        0.2,
        'rgba(107,63,212,.48)',
        0.5,
        'rgba(192,45,131,.72)',
        0.75,
        'rgba(228,61,48,.86)',
        1,
        'rgba(255,176,0,.96)',
      ],
    },
  });
  atlasMap.addLayer({
    id: LAYER_POINTS,
    type: 'circle',
    source: SOURCE_POINTS,
    paint: {
      'circle-color': ['match', ['get', 'type'], 'BLE', '#6b3fd4', '#e43d30'],
      'circle-radius': ['interpolate', ['linear'], ['get', 'rssi'], -127, 3, -20, 7.5],
      'circle-stroke-color': '#172a46',
      'circle-stroke-width': 1.15,
      'circle-opacity': 0.96,
    },
  });

  atlasMap.addSource(SOURCE_CLUSTERS, {
    type: 'geojson',
    data: emptyFeatureCollection(),
    cluster: true,
    clusterMaxZoom: 16,
    clusterRadius: 42,
  });
  atlasMap.addLayer({
    id: LAYER_CLUSTER_CIRCLES,
    type: 'circle',
    source: SOURCE_CLUSTERS,
    filter: ['has', 'point_count'],
    paint: {
      'circle-color': ['step', ['get', 'point_count'], '#f4513a', 50, '#d73552', 300, '#7a2fc2'],
      'circle-radius': ['step', ['get', 'point_count'], 14, 50, 19, 300, 25],
      'circle-stroke-color': '#172a46',
      'circle-stroke-width': 1.8,
    },
  });
  if (state.basemap) {
    atlasMap.addLayer({
      id: LAYER_CLUSTER_COUNT,
      type: 'symbol',
      source: SOURCE_CLUSTERS,
      filter: ['has', 'point_count'],
      layout: { 'text-field': ['get', 'point_count_abbreviated'], 'text-font': ['Noto Sans Regular'], 'text-size': 10 },
      paint: { 'text-color': '#ffffff' },
    });
  }
  atlasMap.addLayer({
    id: LAYER_CLUSTER_POINTS,
    type: 'circle',
    source: SOURCE_CLUSTERS,
    filter: ['!', ['has', 'point_count']],
    paint: {
      'circle-color': ['match', ['get', 'type'], 'BLE', '#6b3fd4', '#e43d30'],
      'circle-radius': 5,
      'circle-stroke-color': '#172a46',
      'circle-stroke-width': 1.15,
    },
  });

  applyLayerVisibility();
  notableExplorer.addMapLayers();
  movementExplorer.addMapLayers();
}

function emptyFeatureCollection(): FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}

function pointCollection(records: readonly PreparedRecord[]): FeatureCollection<Point> {
  return {
    type: 'FeatureCollection',
    features: records.map((record) => ({
      type: 'Feature',
      properties: {
        recordId: record.id,
        type: record.type,
        rssi: record.rssi ?? -100,
      },
      geometry: { type: 'Point', coordinates: [record.longitude, record.latitude] },
    })),
  };
}

function routeCollection(records: readonly PreparedRecord[]): FeatureCollection<LineString> {
  const sessions = [...new Set(records.map((record) => record.session))];
  return {
    type: 'FeatureCollection',
    features: sessions.flatMap((session) => {
      const ordered = records
        .filter((record) => record.session === session && record.timestamp !== null)
        .sort((a, b) => (a.timestamp ?? 0) - (b.timestamp ?? 0));
      if (ordered.length < 2) return [];
      return [
        {
          type: 'Feature' as const,
          properties: {},
          geometry: {
            type: 'LineString' as const,
            coordinates: ordered.map((record) => [record.longitude, record.latitude]),
          },
        },
      ];
    }),
  };
}

function syncMapData(): void {
  if (!state.mapReady || !atlasMap.getSource(SOURCE_POINTS)) return;
  const points = pointCollection(state.filtered);
  (atlasMap.getSource(SOURCE_POINTS) as GeoJSONSource).setData(points);
  (atlasMap.getSource(SOURCE_CLUSTERS) as GeoJSONSource).setData(points);
  (atlasMap.getSource(SOURCE_ROUTE) as GeoJSONSource).setData(routeCollection(state.filtered));
  applyLayerVisibility();
}

function setLayerVisibility(layerId: string, visible: boolean): void {
  if (atlasMap.getLayer(layerId)) atlasMap.setLayoutProperty(layerId, 'visibility', visible ? 'visible' : 'none');
}

function applyLayerVisibility(): void {
  if (!state.mapReady) return;
  setLayerVisibility(LAYER_POINTS, state.view === 'points');
  setLayerVisibility(LAYER_HEATMAP, state.view === 'heatmap');
  setLayerVisibility(LAYER_CLUSTER_CIRCLES, state.view === 'clusters');
  setLayerVisibility(LAYER_CLUSTER_COUNT, state.view === 'clusters');
  setLayerVisibility(LAYER_CLUSTER_POINTS, state.view === 'clusters');
  setLayerVisibility(LAYER_ROUTE_CASING, state.route);
  setLayerVisibility(LAYER_ROUTE, state.route);
}

function gridStepForZoom(zoom: number): number {
  if (zoom < 5) return 10;
  if (zoom < 7) return 2;
  if (zoom < 9) return 0.5;
  if (zoom < 11) return 0.1;
  if (zoom < 13) return 0.02;
  if (zoom < 15) return 0.005;
  return 0.001;
}

function makeOfflineGrid(): FeatureCollection<LineString> {
  const bounds = atlasMap.getBounds();
  const step = gridStepForZoom(atlasMap.getZoom());
  const features: FeatureCollection<LineString>['features'] = [];
  for (let lng = Math.floor(bounds.getWest() / step) * step; lng <= bounds.getEast(); lng += step) {
    features.push({
      type: 'Feature',
      properties: {},
      geometry: {
        type: 'LineString',
        coordinates: [
          [lng, bounds.getSouth()],
          [lng, bounds.getNorth()],
        ],
      },
    });
  }
  for (let lat = Math.floor(bounds.getSouth() / step) * step; lat <= bounds.getNorth(); lat += step) {
    features.push({
      type: 'Feature',
      properties: {},
      geometry: {
        type: 'LineString',
        coordinates: [
          [bounds.getWest(), lat],
          [bounds.getEast(), lat],
        ],
      },
    });
  }
  return { type: 'FeatureCollection', features };
}

function updateOfflineGrid(): void {
  const source = atlasMap.getSource(SOURCE_GRID) as GeoJSONSource | undefined;
  if (source) source.setData(makeOfflineGrid());
}

function setBasemap(enabled: boolean): void {
  state.basemap = enabled;
  state.mapReady = false;
  state.mapErrorShown = false;
  elements.mapDataStatus.textContent = enabled ? 'Street map · OpenFreeMap' : 'Offline background · no tile requests';
  elements.coordinateReadout.textContent = enabled
    ? 'Street map · OpenFreeMap tiles'
    : 'Offline background · no tile requests';
  atlasMap.setStyle(enabled ? MAP_STYLE : offlineStyle());
}

async function shortHash(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value || 'unknown');
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest).slice(0, 4), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function prepareRecords(records: readonly WardriveRecord[]): Promise<PreparedRecord[]> {
  const digests = new Map<string, Promise<string | null>>();
  const digest = (record: WardriveRecord): Promise<string | null> => {
    const key = `${record.type}:${normalizeAddress(record.bssid) ?? record.bssid}`;
    let value = digests.get(key);
    if (!value) {
      value = identityDigest(record);
      digests.set(key, value);
    }
    return value;
  };
  return Promise.all(
    records.map(async (record) => ({
      ...record,
      id: crypto.randomUUID(),
      ssidHash: await shortHash(record.ssid),
      bssidHash: await shortHash(normalizeAddress(record.bssid) ?? record.bssid),
      identityDigest: await digest(record),
    })),
  );
}

function escapeHtml(value: string | number): string {
  const entities: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    "'": '&#39;',
    '"': '&quot;',
  };
  return String(value).replace(/[&<>'"]/g, (character) => entities[character] ?? character);
}

function escapeAttribute(value: string | number): string {
  return escapeHtml(value);
}

type FilterKey = 'band' | 'security' | 'channel';

function uniqueSorted(key: FilterKey, numeric = false): Array<string | number> {
  const values = [...new Set(state.records.map((record) => record[key]).filter((value) => value !== null))];
  return values.sort((a, b) => (numeric ? Number(a) - Number(b) : String(a).localeCompare(String(b))));
}

function populateSelect(select: HTMLSelectElement, values: readonly (string | number)[], label: string): void {
  const active = select.value;
  select.innerHTML = `<option value="all">All ${label}</option>`;
  values.forEach((value) => {
    const option = document.createElement('option');
    option.value = String(value);
    option.textContent = String(value);
    select.append(option);
  });
  select.value = [...select.options].some((option) => option.value === active) ? active : 'all';
}

function toLocalInput(timestamp: number): string {
  const date = new Date(timestamp - new Date(timestamp).getTimezoneOffset() * 60000);
  return date.toISOString().slice(0, 16);
}

function rebuildControls(): void {
  const sessions = [...new Set(state.records.map((record) => record.session))];
  elements.sessionFilter.innerHTML = '';
  sessions.forEach((session) => {
    const count = state.records.filter((record) => record.session === session).length;
    const label = document.createElement('label');
    label.className = 'session-check';
    label.innerHTML = `<input type="checkbox" value="${escapeAttribute(session)}" ${state.sessions.has(session) ? 'checked' : ''} /><span title="${escapeAttribute(session)}">${escapeHtml(session)}</span><small>${count.toLocaleString()}</small>`;
    elements.sessionFilter.append(label);
  });

  populateSelect(elements.bandFilter, uniqueSorted('band'), 'bands');
  populateSelect(elements.securityFilter, uniqueSorted('security'), 'security');
  populateSelect(elements.channelFilter, uniqueSorted('channel', true), 'channels');
  const timestamps = state.records
    .map((record) => record.timestamp)
    .filter((timestamp): timestamp is number => timestamp !== null);
  if (timestamps.length) {
    elements.timeFrom.min = elements.timeTo.min = toLocalInput(Math.min(...timestamps));
    elements.timeFrom.max = elements.timeTo.max = toLocalInput(Math.max(...timestamps));
  }

  elements.sessionSummary.innerHTML = sessions
    .map((session) => {
      const count = state.records.filter((record) => record.session === session).length;
      return `<div class="session-row"><i></i><div><strong title="${escapeAttribute(session)}">${escapeHtml(session)}</strong><span>${count.toLocaleString()} observations</span></div><button type="button" data-remove-session="${escapeAttribute(session)}" aria-label="Remove ${escapeAttribute(session)}">×</button></div>`;
    })
    .join('');
}

async function importFiles(files: FileList | readonly File[] | null): Promise<void> {
  if (!files) return;
  const csvFiles = [...files].filter((file) => file.name.toLowerCase().endsWith('.csv') || file.type === 'text/csv');
  if (!csvFiles.length) {
    showToast('Choose one or more CSV files.');
    return;
  }

  let imported = 0;
  const errors: string[] = [];
  for (const file of csvFiles) {
    try {
      const parsed = parseWardriveCsv(await file.text(), file.name);
      let sessionName = file.name;
      let duplicate = 2;
      while (state.records.some((record) => record.session === sessionName)) {
        sessionName = `${file.name} (${duplicate++})`;
      }
      const renamed = parsed.map((record, index) => ({
        ...record,
        session: sessionName,
        id: `${sessionName}:${index}`,
      }));
      const prepared = await prepareRecords(renamed);
      state.records.push(...prepared);
      prepared.forEach((record) => state.recordsById.set(record.id, record));
      state.sessions.add(sessionName);
      imported += parsed.length;
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : 'The file could not be read.';
      errors.push(`${file.name}: ${message}`);
    }
  }

  if (imported) {
    afterDataChange();
    fitToRecords(state.records);
    showToast(
      `${imported.toLocaleString()} observations added from ${csvFiles.length - errors.length} ${csvFiles.length - errors.length === 1 ? 'file' : 'files'}.`,
    );
  }
  if (errors.length) showToast(errors[0]);
  elements.fileInput.value = '';
}

function makeSampleRecords(): WardriveRecord[] {
  const center = { lat: 40.718, lng: -73.973 };
  const networks: ReadonlyArray<
    readonly [ssid: string, security: WardriveRecord['security'], channel: number, type: WardriveRecord['type']]
  > = [
    ['Juniper Guest', 'WPA2', 6, 'Wi-Fi'],
    ['Cedar House', 'WPA3', 149, 'Wi-Fi'],
    ['Corner Coffee', 'Open', 11, 'Wi-Fi'],
    ['Studio 4B', 'WPA2', 44, 'Wi-Fi'],
    ['Bike Sensor', 'Open', 37, 'BLE'],
    ['Beacon 27', 'Open', 38, 'BLE'],
    ['North Library', 'WPA2', 1, 'Wi-Fi'],
    ['MESH_NODE', 'WPA3', 213, 'Wi-Fi'],
  ];
  const records: WardriveRecord[] = [];
  for (let index = 0; index < 94; index += 1) {
    const section = index / 93;
    const turn = section * Math.PI * 3.4;
    const lane = Math.sin(turn * 0.7) * 0.0045;
    const network = networks[index % networks.length];
    if (!network) continue;
    const [ssid, security, channel, type] = network;
    records.push({
      id: `Sample drive:${index}`,
      session: 'Sample drive · August 29',
      bssid:
        `${(index % 240).toString(16).padStart(2, '0')}:A4:2B:${((index * 7) % 255).toString(16).padStart(2, '0')}:8C:11`.toUpperCase(),
      ssid,
      authMode: security,
      security,
      channel,
      band: type === 'BLE' ? 'Bluetooth' : channel <= 14 ? '2.4 GHz' : channel <= 177 ? '5 GHz' : '6 GHz',
      rssi: -31 - ((index * 13) % 58),
      latitude: center.lat + (section - 0.5) * 0.045 + lane,
      longitude: center.lng + Math.sin(turn) * 0.016 + (section - 0.5) * 0.012,
      altitude: 8 + Math.sin(turn) * 3,
      accuracy: 3 + (index % 5),
      manufacturerId: null,
      type,
      firstSeen: new Date(Date.UTC(2026, 7, 29, 13, 20 + index)).toISOString(),
      timestamp: Date.UTC(2026, 7, 29, 13, 20 + index),
    });
  }
  // Clearly synthetic examples exercise the complete notable workflow without real captures.
  const examples: Array<[number, Partial<WardriveRecord>]> = [
    [
      10,
      { bssid: 'B4:1E:52:00:00:01', ssid: 'Penguin-SAMPLE', type: 'BLE', band: 'Bluetooth', manufacturerId: '09C8' },
    ],
    [11, { bssid: 'B4:1E:52:00:00:01', ssid: 'Penguin-SAMPLE', type: 'BLE', band: 'Bluetooth', rssi: -35 }],
    [
      39,
      {
        bssid: '00:25:DF:00:00:02',
        ssid: 'Sample body camera',
        type: 'BLE',
        band: 'Bluetooth',
        manufacturerId: '034D',
      },
    ],
    [65, { bssid: 'DA:00:00:00:00:03', ssid: 'Ray-Ban SAMPLE', type: 'BLE', band: 'Bluetooth' }],
    [83, { bssid: '70:C9:4E:00:00:04', ssid: 'Sample research lead', type: 'Wi-Fi', band: '2.4 GHz', channel: 6 }],
  ];
  for (const [index, changes] of examples) Object.assign(records[index]!, changes);
  // A shared-route companion is a synthetic movement example, not a threat.
  for (const index of [15, 20, 25, 30, 35])
    Object.assign(records[index]!, {
      bssid: 'DA:00:00:00:00:99',
      ssid: 'Sample travel companion',
      type: 'BLE',
      band: 'Bluetooth',
    });
  return WardriveRecordSchema.array().parse(records);
}

async function loadSample(): Promise<void> {
  if (state.sampleLoaded) {
    showToast('The sample drive is already loaded.');
    return;
  }
  const records = await prepareRecords(makeSampleRecords());
  state.records.push(...records);
  records.forEach((record) => state.recordsById.set(record.id, record));
  const firstRecord = records[0];
  if (!firstRecord) return;
  state.sessions.add(firstRecord.session);
  state.sampleLoaded = true;
  afterDataChange();
  fitToRecords(records);
  showToast('Sample drive loaded. Try the filters and map views.');
}

function afterDataChange(): void {
  const hasData = state.records.length > 0;
  elements.emptyState.hidden = hasData;
  elements.filterPanel.hidden = !hasData;
  elements.sessionsPanel.hidden = !hasData;
  elements.statsStrip.hidden = !hasData;
  elements.viewSwitcher.hidden = !hasData;
  elements.legend.hidden = !hasData;
  rebuildControls();
  applyFilters();
  requestAnimationFrame(() => atlasMap.resize());
}

function applyFilters(): void {
  const type = elements.typeFilter.value;
  const band = elements.bandFilter.value;
  const security = elements.securityFilter.value;
  const channel = elements.channelFilter.value;
  const minimumRssi = Number(elements.rssiFilter.value);
  const timeFrom = elements.timeFrom.value ? new Date(elements.timeFrom.value).getTime() : null;
  const timeTo = elements.timeTo.value ? new Date(elements.timeTo.value).getTime() : null;

  state.filtered = state.records.filter(
    (record) =>
      state.sessions.has(record.session) &&
      (type === 'all' || record.type === type) &&
      (band === 'all' || record.band === band) &&
      (security === 'all' || record.security === security) &&
      (channel === 'all' || String(record.channel) === channel) &&
      (timeFrom === null || record.timestamp === null || record.timestamp >= timeFrom) &&
      (timeTo === null || record.timestamp === null || record.timestamp <= timeTo) &&
      (record.rssi === null || record.rssi >= minimumRssi),
  );

  elements.rssiOutput.value = `${String(minimumRssi).replace('-', '−')} dBm`;
  elements.visibleCount.textContent = state.filtered.length.toLocaleString();
  elements.wifiCount.textContent = state.filtered.filter((record) => record.type === 'Wi-Fi').length.toLocaleString();
  elements.bleCount.textContent = state.filtered.filter((record) => record.type === 'BLE').length.toLocaleString();
  const strongest = state.filtered.reduce(
    (best, record) => (record.rssi !== null && record.rssi > best ? record.rssi : best),
    -Infinity,
  );
  elements.strongestRssi.textContent = Number.isFinite(strongest) ? `${strongest} dBm` : '—';
  if (state.selected && !state.filtered.includes(state.selected)) closeDetail();
  notableExplorer.update(state.filtered, state.records.length > 0);
  movementExplorer.update(state.filtered, state.records);
  syncMapData();
}

function fitToRecords(records: readonly WardriveRecord[]): void {
  if (!records.length) return;
  if (!state.mapReady) {
    state.pendingFit = [...records];
    return;
  }
  const bounds = new maplibregl.LngLatBounds();
  records.forEach((record) => bounds.extend([record.longitude, record.latitude]));
  atlasMap.fitBounds(bounds, {
    padding: window.innerWidth <= 820 ? 44 : 70,
    maxZoom: 16,
    duration: 650,
  });
}

function displaySsid(record: PreparedRecord): string {
  if (state.privacy.ssid === 'hide') return 'Private network';
  if (state.privacy.ssid === 'hash') return `Network ${record.ssidHash}`;
  return record.ssid;
}

function displayBssid(record: PreparedRecord): string {
  if (state.privacy.bssid === 'hide') return 'Hidden';
  if (state.privacy.bssid === 'hash') return `Device ${record.bssidHash}`;
  return record.bssid;
}

function formatTime(record: PreparedRecord): string {
  if (record.timestamp === null) return record.firstSeen || 'Unknown';
  return new Date(record.timestamp).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
}

function showDetail(record: PreparedRecord): void {
  notableExplorer.closeSelection();
  movementExplorer.closeSelection();
  state.selected = record;
  elements.detailType.textContent = `${record.type} observation`;
  elements.detailName.textContent = displaySsid(record);
  const details: Array<readonly [string, string | number]> = [
    ['Address', displayBssid(record)],
    ['Signal', record.rssi === null ? 'Unknown' : `${record.rssi} dBm`],
    ['Channel', record.channel ?? 'Unknown'],
    ['Band', record.band],
    ['Security', record.security],
    ['Seen', formatTime(record)],
    ['Latitude', record.latitude.toFixed(6)],
    ['Longitude', record.longitude.toFixed(6)],
    ['Session', record.session],
  ];
  elements.detailList.innerHTML = details
    .map(([term, value]) => `<div><dt>${term}</dt><dd>${escapeHtml(value)}</dd></div>`)
    .join('');
  elements.detailCard.hidden = false;
}

function closeDetail(): void {
  state.selected = null;
  elements.detailCard.hidden = true;
  elements.detailName.textContent = '';
  elements.detailList.replaceChildren();
}

function resetFilters(): void {
  elements.typeFilter.value = 'all';
  elements.bandFilter.value = 'all';
  elements.securityFilter.value = 'all';
  elements.channelFilter.value = 'all';
  elements.timeFrom.value = '';
  elements.timeTo.value = '';
  elements.rssiFilter.value = '-127';
  elements.sessionFilter.querySelectorAll<HTMLInputElement>('input').forEach((input) => {
    input.checked = true;
    state.sessions.add(input.value);
  });
  applyFilters();
}

function clearAll(): void {
  notableExplorer.clearCapture();
  state.records = [];
  state.filtered = [];
  state.recordsById.clear();
  state.sessions.clear();
  state.sampleLoaded = false;
  closeDetail();
  resetFilters();
  state.sessions.clear();
  afterDataChange();
  showToast('All loaded data cleared from this tab.');
}

function removeSession(session: string): void {
  const removed = state.records.filter((record) => record.session === session);
  removed.forEach((record) => state.recordsById.delete(record.id));
  state.records = state.records.filter((record) => record.session !== session);
  notableExplorer.pruneDismissals(state.records);
  state.sessions.delete(session);
  if (session.startsWith('Sample drive')) state.sampleLoaded = false;
  closeDetail();
  afterDataChange();
  if (state.records.length) fitToRecords(state.records);
  showToast(`${session} removed.`);
}

function openFiles(): void {
  elements.fileInput.click();
}

elements.fileInput.addEventListener('change', () => importFiles(elements.fileInput.files));
[elements.addFilesButton, elements.emptyAddButton].forEach((button) => button.addEventListener('click', openFiles));
[elements.emptySampleButton, elements.loadSample].forEach((button) => button.addEventListener('click', loadSample));
elements.dropZone.addEventListener('click', openFiles);
elements.dropZone.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' || event.key === ' ') openFiles();
});
elements.dropZone.addEventListener('dragover', (event) => {
  event.preventDefault();
  elements.dropZone.classList.add('dragging');
});
elements.dropZone.addEventListener('dragleave', () => elements.dropZone.classList.remove('dragging'));
elements.dropZone.addEventListener('drop', (event) => {
  event.preventDefault();
  elements.dropZone.classList.remove('dragging');
  void importFiles(event.dataTransfer?.files ?? null);
});

[
  elements.typeFilter,
  elements.bandFilter,
  elements.securityFilter,
  elements.channelFilter,
  elements.timeFrom,
  elements.timeTo,
].forEach((control) => control.addEventListener('change', applyFilters));
elements.rssiFilter.addEventListener('input', applyFilters);
elements.sessionFilter.addEventListener('change', (event) => {
  if (!(event.target instanceof HTMLInputElement)) return;
  if (event.target.checked) state.sessions.add(event.target.value);
  else state.sessions.delete(event.target.value);
  applyFilters();
});
elements.routeToggle.addEventListener('change', () => {
  state.route = elements.routeToggle.checked;
  applyLayerVisibility();
});
elements.basemapToggle.addEventListener('change', () => setBasemap(elements.basemapToggle.checked));
elements.resetFilters.addEventListener('click', resetFilters);
elements.clearAll.addEventListener('click', clearAll);
elements.sessionSummary.addEventListener('click', (event) => {
  if (!(event.target instanceof Element)) return;
  const button = event.target.closest<HTMLButtonElement>('[data-remove-session]');
  const session = button?.dataset['removeSession'];
  if (session) removeSession(session);
});

elements.viewSwitcher.addEventListener('click', (event) => {
  if (!(event.target instanceof Element)) return;
  const button = event.target.closest<HTMLButtonElement>('[data-view]');
  if (!button) return;
  const viewResult = ViewModeSchema.safeParse(button.dataset['view']);
  if (!viewResult.success) return;
  state.view = viewResult.data;
  elements.viewSwitcher
    .querySelectorAll('button')
    .forEach((candidate) => candidate.classList.toggle('active', candidate === button));
  closeDetail();
  applyLayerVisibility();
});

elements.fitMap.addEventListener('click', () => fitToRecords(state.filtered.length ? state.filtered : state.records));
elements.closeDetail.addEventListener('click', closeDetail);

elements.privacyButton.addEventListener('click', () => elements.privacyDialog.showModal());
elements.privacyDialog.addEventListener('close', () => {
  const form = elements.privacyDialog.querySelector('form');
  if (!form) return;
  const formData = new FormData(form);
  const privacyResult = PrivacySettingsSchema.safeParse({
    ssid: formData.get('ssidPrivacy'),
    bssid: formData.get('bssidPrivacy'),
  });
  if (!privacyResult.success) {
    showToast('Privacy settings could not be applied.');
    return;
  }
  state.privacy = privacyResult.data;
  if (state.selected) showDetail(state.selected);
  notableExplorer.refreshPrivacy();
  movementExplorer.refreshPrivacy();
  showToast('Privacy settings applied.');
});

window.addEventListener('resize', () => atlasMap.resize());

const atlasMap = initializeMap();
const notableExplorer = new NotableExplorer({
  map: atlasMap,
  name: (record) => displaySsid(state.recordsById.get(record.id)!),
  address: (record) => displayBssid(state.recordsById.get(record.id)!),
  fit: fitToRecords,
  onSelect: () => {
    closeDetail();
    movementExplorer.closeSelection();
  },
  onRulesChange: () => movementExplorer.recalculate(),
});
const movementExplorer = new CoTravelExplorer({
  map: atlasMap,
  name: (record) => displaySsid(state.recordsById.get(record.id)!),
  address: (record) => displayBssid(state.recordsById.get(record.id)!),
  digest: (record) => state.recordsById.get(record.id)?.identityDigest ?? null,
  alias: (digest) => (state.privacy.bssid === 'hide' ? 'Hidden' : `Saved device ${digest.slice(0, 12)}`),
  customPrefixes: () => notableExplorer.customPrefixes(),
  fit: fitToRecords,
  onSelect: () => {
    closeDetail();
    notableExplorer.closeSelection();
  },
});
import.meta.hot?.dispose(() => movementExplorer.dispose());
for (const id of ['showNotable', 'showMovement'])
  requiredElement(id).addEventListener('click', () => {
    const movement = id === 'showMovement';
    requiredElement('showNotable').setAttribute('aria-pressed', String(!movement));
    requiredElement('showMovement').setAttribute('aria-pressed', String(movement));
    requiredElement('analysisLegend').innerHTML = movement
      ? '<i class="movement-dot"></i>Movement'
      : '<i class="notable-dot"></i>Notable';
    closeDetail();
    notableExplorer.setActive(!movement);
    movementExplorer.setActive(movement);
  });
