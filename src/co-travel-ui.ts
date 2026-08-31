import type { Map as AtlasMap, GeoJSONSource, PointLike } from 'maplibre-gl';
import type { WardriveRecord } from './csv';
import type { RuleSettings } from './notable';
import { assessmentView, usablePosition } from './co-travel';
import { CoTravelRunner } from './co-travel-runner';
import {
  CoTravelViewSchema,
  SensitivitySchema,
  THRESHOLDS,
  emptyCoTravelAnalysis,
  type CoTravelAnalysis,
  type CoTravelAssessment,
  type CoTravelView,
  type Sensitivity,
} from './co-travel-schema';
import { trustedIdentity as trustKey, type TrustedDevice, type TrustOperation } from './co-travel-trust';
import { createBrowserTrustController } from './co-travel-trust-browser';
import { movementPins, movementSelection } from './co-travel-map';

export const MOVEMENT_PINS = 'movement-pins';
const SOURCE = 'movement-observations',
  SIGHTINGS = 'movement-sightings',
  PATHS = 'movement-paths';
const VIEW_LABELS = { candidates: 'Candidates', observed: 'Observed', context: 'Context', trusted: 'Trusted' } as const;
function el<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing movement control: ${id}`);
  return element as T;
}
function escape(value: string | number): string {
  const entities: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  return String(value).replace(/[&<>"']/g, (character) => entities[character]!);
}
function time(value: number | null): string {
  return value === null
    ? 'Unavailable'
    : new Date(value).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' });
}
function meters(value: number): string {
  return value >= 1000 ? `${(value / 1000).toFixed(2)} km` : `${Math.floor(value)} m`;
}
function span(first: number, last: number): string {
  return `${((last - first) / 60_000).toFixed(1)} min`;
}
interface ExplorerHost {
  map: AtlasMap;
  name(record: WardriveRecord): string;
  address(record: WardriveRecord): string;
  digest(record: WardriveRecord): string | null;
  alias(digest: string): string;
  fit(records: readonly WardriveRecord[]): void;
  customPrefixes(): RuleSettings['custom'];
  onSelect(): void;
}

export class CoTravelExplorer {
  private readonly runner = new CoTravelRunner(
    () => new Worker(new URL('./co-travel-worker.ts', import.meta.url), { type: 'module' }),
  );
  private readonly trustController = createBrowserTrustController();
  private trustState = this.trustController.getSnapshot();
  private readonly unsubscribeTrust: () => void;
  private trustKeys = new Set<string>();
  private error = '';
  private active = false;
  private busy = false;
  private sensitivity: Sensitivity = 'medium';
  private view: CoTravelView = 'candidates';
  private analysis: CoTravelAnalysis = emptyCoTravelAnalysis();
  private records: readonly WardriveRecord[] = [];
  private recordsById = new Map<string, WardriveRecord>();
  private loadedByDigest = new Map<string, WardriveRecord>();
  private visible: CoTravelAssessment[] = [];
  private selectedId: string | null = null;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private listLimit = 50;
  private timelineLimit = 50;

  constructor(private readonly host: ExplorerHost) {
    el<HTMLSelectElement>('movementSensitivity').addEventListener('change', (event) => {
      const result = SensitivitySchema.safeParse((event.currentTarget as HTMLSelectElement).value);
      if (!result.success) return;
      this.sensitivity = result.data;
      this.recalculate();
    });
    el('movementViews').addEventListener('click', (event) => {
      const button =
        event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-movement-view]') : null;
      const result = CoTravelViewSchema.safeParse(button?.dataset['movementView']);
      if (!result.success) return;
      this.view = result.data;
      this.listLimit = 50;
      this.closeSelection();
      this.render();
      el('movementViews').querySelector<HTMLButtonElement>(`[data-movement-view="${this.view}"]`)?.focus();
    });
    const activate = (event: MouseEvent | KeyboardEvent): void => {
      if (event instanceof KeyboardEvent && event.key !== 'Enter' && event.key !== ' ') return;
      const button = event.target instanceof Element ? event.target.closest<HTMLButtonElement>('button') : null;
      if (!button || button.disabled) return;
      if (event instanceof KeyboardEvent) event.preventDefault();
      if (button.dataset['untrust'] !== undefined) {
        const entry = this.trustState.settings.devices[Number(button.dataset['untrust'])];
        if (entry) this.changeTrust({ action: 'untrust', device: entry });
        el('movementViews').querySelector<HTMLButtonElement>('[data-movement-view="trusted"]')?.focus();
      } else {
        const result = this.visible.find((item) => item.id === button.dataset['movement']);
        if (result) this.select(result);
      }
    };
    el('movementList').addEventListener('click', activate);
    el('movementList').addEventListener('keydown', activate);
    el('movementTrustChanges').addEventListener('click', (event) => {
      const button =
        event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-save-trust]') : null;
      if (!button || button.disabled) return;
      const operation = this.trustState.overrides[Number(button.dataset['saveTrust'])];
      if (operation) this.changeTrust(operation);
      el('movementViews').querySelector<HTMLButtonElement>('[data-movement-view="trusted"]')?.focus();
    });
    el('moreMovement').addEventListener('click', () => {
      this.listLimit += 50;
      this.render();
    });
    el('moreTimeline').addEventListener('click', () => {
      this.timelineLimit += 50;
      this.render();
    });
    el('closeMovement').addEventListener('click', () => this.closeSelection());
    el('trustMovement').addEventListener('click', () => {
      const assessment = this.analysis.assessments.find((item) => item.id === this.selectedId);
      const record = assessment && this.recordsById.get(assessment.representativeId);
      const digest = record && this.host.digest(record);
      if (!record || !digest || this.trustState.pending) return;
      const entry = { digest, type: record.type };
      this.changeTrust({ action: this.trustKeys.has(trustKey(entry)) ? 'untrust' : 'trust', device: entry });
      el('movementViews').querySelector<HTMLButtonElement>(`[data-movement-view="${this.view}"]`)?.focus();
    });
    this.unsubscribeTrust = this.trustController.subscribe((state) => {
      this.trustState = state;
      this.trustKeys = new Set(state.settings.devices.map(trustKey));
      // Trust changes only presentation, never the worker's movement evidence.
      this.render();
    });
  }

  setActive(active: boolean): void {
    this.active = active;
    el('movementPanel').hidden = !active;
    this.recalculate();
  }
  update(records: readonly WardriveRecord[], allRecords: readonly WardriveRecord[]): void {
    this.records = records;
    this.recordsById = new Map(records.map((record) => [record.id, record]));
    this.loadedByDigest.clear();
    for (const record of allRecords) {
      const digest = this.host.digest(record);
      if (digest) this.loadedByDigest.set(trustKey({ digest, type: record.type }), record);
    }
    this.recalculate();
  }
  recalculate(): void {
    clearTimeout(this.timer);
    this.runner.cancel();
    this.closeSelection();
    this.analysis = emptyCoTravelAnalysis();
    this.error = '';
    this.busy = this.active && this.records.length > 0;
    this.listLimit = 50;
    this.render();
    if (!this.busy) return;
    this.timer = setTimeout(() => {
      this.runner.run(
        {
          records: [...this.records],
          settings: { sensitivity: this.sensitivity },
          customPrefixes: this.host.customPrefixes(),
        },
        (result) => {
          this.analysis = result;
          this.busy = false;
          this.render();
        },
        (message) => {
          this.error = message;
          this.busy = false;
          this.render();
        },
      );
    }, 150);
  }
  refreshPrivacy(): void {
    this.render();
  }
  dispose(): void {
    clearTimeout(this.timer);
    this.runner.cancel();
    this.unsubscribeTrust();
    this.trustController.dispose();
  }
  private isTrusted(assessment: CoTravelAssessment): boolean {
    const record = this.recordsById.get(assessment.representativeId);
    const digest = record && this.host.digest(record);
    return !!record && !!digest && this.trustKeys.has(trustKey({ type: record.type, digest }));
  }
  private changeTrust(operation: TrustOperation): void {
    if (this.trustState.pending) return;
    // Capture the explicit action and target now, not after a render or lock wait.
    void this.trustController.mutate({ action: operation.action, device: { ...operation.device } });
  }
  private trustNote(entry: TrustedDevice): string {
    const override = this.trustState.overrides.find((operation) => trustKey(operation.device) === trustKey(entry));
    if (override) return override.action === 'trust' ? 'Tab-only: trusted' : 'Tab-only: trust removed';
    return this.trustKeys.has(trustKey(entry)) ? 'Saved trust' : '';
  }
  private status(assessment: CoTravelAssessment): string {
    if (this.isTrusted(assessment)) return 'Trusted';
    if (assessment.context)
      return assessment.context === 'wifi'
        ? 'Wi-Fi context'
        : `${assessment.contextLabels.map((label) => (label === 'flock' ? 'Flock' : 'Axon')).join(' / ')} signature context`;
    return assessment.window?.qualifies ? 'Co-travel candidate' : 'Observed';
  }
  private render(): void {
    const focused = document.activeElement;
    const focusedView = focused instanceof HTMLElement ? focused.dataset['movementView'] : undefined;
    const focusedResult = focused instanceof HTMLElement ? focused.dataset['movement'] : undefined;
    const counts: Record<CoTravelView, number> = {
      candidates: 0,
      observed: 0,
      context: 0,
      trusted: this.trustState.settings.devices.length,
    };
    this.visible = this.analysis.assessments.filter((item) => {
      const view = assessmentView(item, this.isTrusted(item));
      if (view !== 'trusted') counts[view]++;
      return view === this.view;
    });
    el('movementViews').innerHTML = (Object.keys(VIEW_LABELS) as CoTravelView[])
      .map(
        (view) =>
          `<button type="button" data-movement-view="${view}" aria-pressed="${this.view === view}">${VIEW_LABELS[view]} <b>${this.busy && view !== 'trusted' ? '…' : counts[view]}</b></button>`,
      )
      .join('');
    const warning = [
      this.trustState.warning,
      this.trustState.overrides.length ? 'Open Trusted to save a tab-only change explicitly.' : '',
      this.error,
    ]
      .filter(Boolean)
      .join(' ');
    el('movementWarning').textContent = warning;
    el('movementWarning').hidden = !warning;
    el('movementTrustChanges').hidden = this.view !== 'trusted' || !this.trustState.overrides.length;
    el('movementTrustChanges').innerHTML = this.trustState.overrides
      .map((operation, index) => {
        const entry = operation.device;
        const loaded = this.loadedByDigest.get(trustKey(entry));
        return `<li class="trusted-saved"><span><strong>${escape(this.trustNote(entry))}</strong><span>${escape(loaded ? this.host.name(loaded) : 'Address not in loaded captures')}</span><span>${escape(loaded ? this.host.address(loaded) : this.host.alias(entry.digest))} · ${entry.type}</span></span><button type="button" class="text-button small" data-save-trust="${index}" ${this.trustState.pending ? 'disabled' : ''}>Save change</button></li>`;
      })
      .join('');
    el('movementList').setAttribute('aria-busy', String(this.busy));
    el('movementStatus').textContent = this.busy
      ? 'Reviewing evidence on this device…'
      : this.view === 'trusted'
        ? `${counts.trusted} trusted addresses · ${this.trustState.saved.devices.length} saved · ${this.trustState.overrides.length} tab-only changes · ${this.visible.length} in this filtered view`
        : `${counts.candidates.toLocaleString()} qualifying Bluetooth addresses · ${this.sensitivity} sensitivity`;
    const sightings = this.visible.reduce((sum, item) => sum + item.sightings.length, 0);
    const locations = this.visible.reduce((sum, item) => sum + item.locations, 0);
    el('movementMetrics').innerHTML =
      `<div><strong>${sightings.toLocaleString()}</strong><span>independent sightings</span></div><div><strong>${locations.toLocaleString()}</strong><span>locations per address, summed</span></div>`;
    el('movementMetrics').hidden = this.busy || !this.visible.length;
    const rows = this.visible.slice(0, this.listLimit).map((item) => {
      const record = this.recordsById.get(item.representativeId)!;
      const window = item.window;
      const digest = this.host.digest(record);
      const note = digest ? this.trustNote({ digest, type: record.type }) : '';
      return `<li><button type="button" class="candidate-row movement-row" data-movement="${item.id}" aria-pressed="${item.id === this.selectedId}"><span class="movement-symbol" aria-hidden="true">↗</span><span class="candidate-copy"><strong>${escape(this.status(item))}</strong><span>${escape(this.host.name(record))}</span><span class="candidate-address">${escape(this.host.address(record))} · ${item.type}</span><small>${window ? `${window.sightingIds.length} sightings · ${window.locations} places · ${span(window.first, window.last)} · ${meters(window.travelMeters)}` : 'No usable time / GPS evidence'}</small><small>${item.sessions} ${item.sessions === 1 ? 'session' : 'sessions'} · strongest window above</small>${note ? `<small>${escape(note)}</small>` : ''}</span></button></li>`;
    });
    if (this.view === 'trusted') {
      // Entries absent from filtered data are still reversible, even after clearing captures.
      const represented = new Set(
        this.visible.map((item) => {
          const record = this.recordsById.get(item.representativeId)!;
          return trustKey({ type: record.type, digest: this.host.digest(record)! });
        }),
      );
      this.trustState.settings.devices.forEach((entry, index) => {
        if (represented.has(trustKey(entry)) || rows.length >= this.listLimit) return;
        const loaded = this.loadedByDigest.get(trustKey(entry));
        rows.push(
          `<li class="trusted-saved"><span><strong>${escape(loaded ? this.host.name(loaded) : 'Trusted address')}</strong><span>${escape(loaded ? this.host.address(loaded) : this.host.alias(entry.digest))} · ${entry.type}</span><small>${escape(this.trustNote(entry))} · ${loaded ? 'Outside current filters' : 'Not in loaded captures'}</small></span><button type="button" class="text-button small" data-untrust="${index}" ${this.trustState.pending ? 'disabled' : ''}>Remove trust</button></li>`,
        );
      });
    }
    el('movementList').innerHTML =
      rows.join('') ||
      `<li class="notable-empty">${this.busy ? 'Checking time, position and repeated sightings…' : this.error ? 'Analysis unavailable. Change sensitivity to retry.' : this.view === 'trusted' ? 'No trusted addresses. Select an observed address to mark your own equipment as trusted.' : this.view === 'context' ? 'No Wi-Fi or Flock/Axon signature context in this view.' : this.view === 'observed' ? 'No other Bluetooth addresses in this view.' : 'No qualifying co-travel evidence in this CSV view. This does not establish that nothing traveled with you.'}</li>`;
    el('moreMovement').hidden = (this.view === 'trusted' ? counts.trusted : this.visible.length) <= this.listLimit;
    const c = this.analysis.coverage;
    el('movementCoverage').textContent = this.busy
      ? 'Coverage is being recalculated.'
      : `${c.total.toLocaleString()} filtered observations (all radios); ${c.eligible.toLocaleString()} with usable evidence, ${c.independent.toLocaleString()} independent sightings, ${c.duplicates.toLocaleString()} same-minute repeats collapsed. ${c.excluded.toLocaleString()} excluded from movement evidence: ${c.invalidAddress} invalid addresses, ${c.invalidTime} missing/invalid times, ${c.invalidFix} unusable positions, ${c.invalidAccuracy} missing/poor accuracy (must be >0 and ≤75 m). Exclusions are counted once, in that order. All rows remain in the ordinary viewer. Context is not proof of fixed infrastructure.`;
    const selected = this.visible.find((item) => item.id === this.selectedId);
    if (selected) this.renderDetail(selected);
    else this.closeSelection();
    this.syncMap();
    // Cross-tab refreshes keep keyboard focus and valid selection in place.
    if (focusedView)
      el('movementViews')
        .querySelector<HTMLButtonElement>(`[data-movement-view="${focusedView}"]`)
        ?.focus({ preventScroll: true });
    else if (focusedResult && selected)
      el('movementList')
        .querySelector<HTMLButtonElement>(`[data-movement="${focusedResult}"]`)
        ?.focus({ preventScroll: true });
    else if ((focusedResult || focused === el('trustMovement')) && !selected)
      el('movementViews')
        .querySelector<HTMLButtonElement>(`[data-movement-view="${this.view}"]`)
        ?.focus({ preventScroll: true });
  }
  private select(assessment: CoTravelAssessment): void {
    this.host.onSelect();
    this.selectedId = assessment.id;
    this.timelineLimit = 50;
    this.render();
    const records = assessment.recordIds.map((id) => this.recordsById.get(id)!).filter(usablePosition);
    if (records.length) this.host.fit(records);
    el('movementList')
      .querySelector<HTMLButtonElement>(`[data-movement="${assessment.id}"]`)
      ?.focus({ preventScroll: true });
    if (window.innerWidth <= 820) el('mapCanvas').scrollIntoView({ behavior: 'instant', block: 'start' });
  }
  closeSelection(): void {
    this.selectedId = null;
    el('movementDetail').hidden = true;
    for (const id of [
      'movementDetailName',
      'movementDetailType',
      'movementDetailList',
      'movementWindow',
      'movementTimeline',
      'movementSignal',
    ])
      el(id).replaceChildren();
    el('movementList')
      .querySelectorAll('[aria-pressed="true"]')
      .forEach((button) => button.setAttribute('aria-pressed', 'false'));
    this.syncMap();
  }
  private renderDetail(assessment: CoTravelAssessment): void {
    const record = this.recordsById.get(assessment.representativeId)!;
    const window = assessment.window;
    el('movementDetailType').textContent = this.status(assessment);
    el('movementDetailName').textContent = this.host.name(record);
    const strong = assessment.recordIds.reduce<number | null>((best, id) => {
      const rssi = this.recordsById.get(id)?.rssi;
      return rssi == null ? best : Math.max(best ?? -Infinity, rssi);
    }, null);
    const entries = [
      ['Address', this.host.address(record)],
      ['Radio', record.type],
      [
        'Your trust',
        this.host.digest(record)
          ? this.trustNote({ digest: this.host.digest(record)!, type: record.type }) || 'Not trusted'
          : 'Unavailable',
      ],
      ['Selected-range rows', assessment.recordIds.length],
      ['Independent sightings', assessment.sightings.length],
      ['Separated locations', assessment.locations],
      ['Selected sessions', assessment.sessions],
      ['First usable sighting', time(assessment.first)],
      ['Last usable sighting', time(assessment.last)],
      ['Strongest signal', strong === null ? 'Unavailable' : `${strong} dBm`],
      [
        'Observed here',
        usablePosition(record)
          ? `${record.latitude.toFixed(5)}, ${record.longitude.toFixed(5)}`
          : 'Position unavailable',
      ],
    ];
    el('movementDetailList').innerHTML = entries
      .map(([key, value]) => `<div><dt>${key}</dt><dd>${escape(value!)}</dd></div>`)
      .join('');
    const threshold = THRESHOLDS[this.sensitivity];
    const checks: Array<[string, boolean]> = window
      ? [
          [
            `${window.sightingIds.length} / ${threshold.sightings} independent sightings`,
            window.sightingIds.length >= threshold.sightings,
          ],
          [`${window.locations} / ${threshold.locations} separated locations`, window.locations >= threshold.locations],
          [
            `${span(window.first, window.last)} / ${threshold.minutes} min elapsed`,
            window.last - window.first >= threshold.minutes * 60_000,
          ],
          [
            `${meters(window.travelMeters)} / ${threshold.meters} m travel span`,
            window.travelMeters + 1e-6 >= threshold.meters,
          ],
        ]
      : [];
    const sessions = window ? new Set(window.sightingIds.map((id) => this.recordsById.get(id)!.session)).size : 0;
    el('movementWindow').innerHTML =
      `<h3>Strongest 12-hour window</h3>${window ? `<p>${escape(time(window.first))} → ${escape(time(window.last))}<br>${sessions} ${sessions === 1 ? 'session' : 'sessions'} · ${this.sensitivity} thresholds</p><ul class="threshold-list">${checks.map(([label, met]) => `<li class="${met ? 'met' : 'unmet'}"><span aria-hidden="true">${met ? '✓' : '○'}</span> ${label}<span class="sr-only"> · ${met ? 'met' : 'not met'}</span></li>`).join('')}</ul><p>Travel span is the greatest straight-line separation minus both GPS accuracy radii. Signal strength is not distance.</p>` : '<p>No eligible sightings: valid time, position and reported accuracy are required.</p>'}${assessment.context ? '<p>Context only, even if the geometric thresholds are met. Camera signatures do not establish fixed infrastructure.</p>' : this.isTrusted(assessment) ? '<p>You marked this address as trusted. Its evidence is retained; it cannot appear in Candidates while trusted.</p>' : ''}`;
    const independent = assessment.sightings.map((item) => ({
      record: this.recordsById.get(item.recordId)!,
      location: item.location,
    }));
    const inWindow = new Set(window?.sightingIds ?? []);
    el('movementTimeline').innerHTML =
      independent
        .slice(0, this.timelineLimit)
        .map(
          ({ record: row, location }) =>
            `<li class="${inWindow.has(row.id) ? 'in-window' : ''}"><span aria-label="${inWindow.has(row.id) ? 'In strongest window' : 'Outside strongest window'}">${inWindow.has(row.id) ? '●' : '○'}</span><div><strong>${escape(time(row.timestamp))}</strong><small>Location ${location + 1} · ±${row.accuracy} m · ${row.rssi === null ? 'signal unavailable' : `${row.rssi} dBm`}</small><small>${escape(row.session)}</small></div></li>`,
        )
        .join('') || '<li>No qualifying timeline evidence.</li>';
    el('moreTimeline').hidden = independent.length <= this.timelineLimit;
    this.renderSignal(independent.map((item) => item.record));
    const trustButton = el<HTMLButtonElement>('trustMovement');
    trustButton.disabled = this.trustState.pending || !this.host.digest(record);
    trustButton.textContent = this.trustState.pending
      ? 'Saving trust change…'
      : this.isTrusted(assessment)
        ? 'Remove trust — restore eligibility'
        : trustButton.disabled
          ? 'A valid address is needed to save trust'
          : 'Mark as trusted';
    el('movementDetail').hidden = false;
  }
  private renderSignal(records: WardriveRecord[]): void {
    const rows = records.filter((record) => record.rssi !== null);
    if (!rows.length) {
      el('movementSignal').textContent = 'No signal values in the independent sightings.';
      return;
    }
    const start = records[0]!.timestamp!,
      end = records.at(-1)!.timestamp!;
    const values = rows.map((record) => record.rssi!);
    const min = values.reduce((a, b) => Math.min(a, b)),
      max = values.reduce((a, b) => Math.max(a, b));
    // Bound chart DOM size; the metrics and paged timeline retain every sighting.
    const chartRows =
      rows.length <= 600
        ? rows
        : Array.from({ length: 600 }, (_, index) => rows[Math.round((index * (rows.length - 1)) / 599)]!);
    const dots = chartRows
      .map(
        (record) =>
          `<circle cx="${8 + ((record.timestamp! - start) / Math.max(1, end - start)) * 264}" cy="${54 - ((record.rssi! - min) / Math.max(1, max - min)) * 42}" r="3"/>`,
      )
      .join('');
    el('movementSignal').innerHTML =
      `<svg class="signal-history" viewBox="0 0 280 64" role="img" aria-label="Signal strength over time, ${min} to ${max} dBm, showing ${chartRows.length} of ${rows.length} independent sightings"><path d="M8 56H272"/>${dots}</svg><p class="signal-caption">${min} to ${max} dBm · earlier → later · dots, not inferred distance${chartRows.length < rows.length ? ` · chart samples ${chartRows.length} of ${rows.length} points; timeline retains all sightings` : ''}</p>`;
  }
  addMapLayers(): void {
    const map = this.host.map;
    for (const solid of [false, true]) {
      const id = `movement-${solid ? 'solid' : 'outline'}`;
      if (map.hasImage(id)) continue;
      const canvas = document.createElement('canvas');
      canvas.width = 80;
      canvas.height = 80;
      const ctx = canvas.getContext('2d');
      if (!ctx) continue;
      ctx.scale(2, 2);
      const shape = new Path2D('M20 3L37 20 20 37 3 20Z');
      ctx.lineJoin = 'round';
      ctx.lineWidth = 6;
      ctx.strokeStyle = '#ffffff';
      ctx.stroke(shape);
      ctx.fillStyle = solid ? '#172a46' : '#f7faf7';
      ctx.fill(shape);
      ctx.lineWidth = 2;
      ctx.strokeStyle = '#172a46';
      ctx.stroke(shape);
      ctx.strokeStyle = solid ? '#ffb000' : '#172a46';
      ctx.lineWidth = 2.5;
      ctx.stroke(new Path2D('M13 26L26 13M16 13H26V23'));
      map.addImage(id, ctx.getImageData(0, 0, 80, 80), { pixelRatio: 2 });
    }
    for (const id of [SOURCE, SIGHTINGS, PATHS])
      map.addSource(id, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map.addLayer({
      id: 'movement-path-casing',
      type: 'line',
      source: PATHS,
      paint: { 'line-color': '#ffffff', 'line-width': 6 },
    });
    map.addLayer({
      id: 'movement-path-lines',
      type: 'line',
      source: PATHS,
      paint: {
        'line-color': ['match', ['%', ['get', 'sessionIndex'], 3], 0, '#172a46', 1, '#6b3fd4', '#e43d30'],
        'line-width': 3,
        'line-dasharray': [2, 1],
      },
    });
    map.addLayer({
      id: 'movement-sighting-halos',
      type: 'circle',
      source: SIGHTINGS,
      paint: {
        'circle-color': '#ffb000',
        'circle-radius': 6,
        'circle-stroke-color': '#172a46',
        'circle-stroke-width': 2,
      },
    });
    map.addLayer({
      id: MOVEMENT_PINS,
      type: 'symbol',
      source: SOURCE,
      layout: { 'icon-image': ['get', 'icon'], 'icon-size': 0.85, 'icon-allow-overlap': false },
    });
    this.syncMap();
  }
  private syncMap(): void {
    const pins = this.host.map.getSource(SOURCE) as GeoJSONSource | undefined;
    const selected = this.active ? this.visible.find((item) => item.id === this.selectedId) : undefined;
    // Trusted/observed/context markers are deliberately hollow even if geometric
    // thresholds are met; a saved trust decision must never look like a candidate.
    const assessments = this.active
      ? this.visible.map((item) =>
          this.isTrusted(item) && item.window ? { ...item, window: { ...item.window, qualifies: false } } : item,
        )
      : [];
    pins?.setData(movementPins(assessments, this.recordsById));
    const selection = movementSelection(selected, this.recordsById);
    (this.host.map.getSource(SIGHTINGS) as GeoJSONSource | undefined)?.setData(selection.points);
    (this.host.map.getSource(PATHS) as GeoJSONSource | undefined)?.setData(selection.paths);
  }
  handleMapClick(point: PointLike): boolean {
    if (!this.active || !this.host.map.getLayer(MOVEMENT_PINS)) return false;
    const feature = this.host.map.queryRenderedFeatures(point, { layers: [MOVEMENT_PINS] })[0];
    const result = this.visible.find((item) => item.id === feature?.properties?.['assessmentId']);
    if (!result) return false;
    this.select(result);
    return true;
  }
}
