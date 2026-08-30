import type { Map as AtlasMap, GeoJSONSource, PointLike } from 'maplibre-gl';
import type { WardriveRecord } from './csv';
import { BUILTIN_CATALOG, CATEGORIES, CATEGORY_LABELS, type Category } from './notable-rules';
import {
  analyzeCandidates,
  candidateFeatures,
  candidateKey,
  CustomPrefixSchema,
  emptyRuleSettings,
  evidenceLabel,
  IgnoredPrefixSchema,
  loadRuleSettings,
  parseRuleSettings,
  saveRuleSettings,
  sortCandidates,
  type Candidate,
  type CandidateSort,
  type RuleSettings,
  type RuleStorage,
} from './notable';
import { addNotableIcons } from './notable-pins';

export const NOTABLE_PINS = 'notable-pins';
const NOTABLE_SOURCE = 'notable-observations';
const SIGHTINGS_SOURCE = 'notable-sightings';

function el<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing notable control: ${id}`);
  return element as T;
}
function escape(value: string | number): string {
  const entities: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  return String(value).replace(/[&<>"']/g, (character) => entities[character]!);
}
function time(value: number | null): string {
  return value === null ? 'Unknown' : new Date(value).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
}
function signal(value: number | null): string {
  return value === null ? 'Unknown signal' : `${value} dBm`;
}

interface ExplorerHost {
  map: AtlasMap;
  name(record: WardriveRecord): string;
  address(record: WardriveRecord): string;
  fit(records: readonly WardriveRecord[]): void;
  onSelect(): void;
}

export class NotableExplorer {
  private readonly host: ExplorerHost;
  private readonly storage: RuleStorage = {
    getItem: (key) => window.localStorage.getItem(key),
    setItem: (key, value) => window.localStorage.setItem(key, value),
  };
  private settings: RuleSettings;
  private records: readonly WardriveRecord[] = [];
  private candidates: Candidate[] = [];
  private visible: Candidate[] = [];
  private dismissed = new Set<string>();
  private selectedKey: string | null = null;
  private category: Category | 'all' = 'all';
  private sort: CandidateSort = 'evidence';
  private research = false;
  private hasData = false;
  private listLimit = 50;
  private readonly panel = el('notablePanel');
  private readonly list = el('notableList');
  private readonly counts = el('notableCategories');
  private readonly detail = el('notableDetail');
  private readonly dialog = el<HTMLDialogElement>('rulesDialog');

  constructor(host: ExplorerHost) {
    this.host = host;
    const loaded = loadRuleSettings(this.storage);
    this.settings = loaded.settings;
    if (loaded.warning) this.warning(loaded.warning);
    el('rulesButton').addEventListener('click', () => {
      this.renderRules();
      this.dialog.showModal();
    });
    el('closeRules').addEventListener('click', () => this.dialog.close());
    el('closeNotable').addEventListener('click', () => this.closeSelection());
    el('dismissCandidate').addEventListener('click', () => {
      if (this.selectedKey) this.dismissed.add(this.selectedKey);
      this.closeSelection();
      this.update(this.records, this.hasData);
      el('restoreCandidates').focus();
    });
    el('restoreCandidates').addEventListener('click', () => {
      this.dismissed.clear();
      this.update(this.records, this.hasData);
    });
    el<HTMLInputElement>('researchToggle').addEventListener('change', (event) => {
      this.research = (event.currentTarget as HTMLInputElement).checked;
      this.listLimit = 50;
      this.update(this.records, this.hasData);
    });
    el<HTMLSelectElement>('notableSort').addEventListener('change', (event) => {
      const value = (event.currentTarget as HTMLSelectElement).value;
      if (value === 'evidence' || value === 'signal' || value === 'recent') this.sort = value;
      this.render();
    });
    this.counts.addEventListener('click', (event) => {
      const button =
        event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-category]') : null;
      const value = button?.dataset['category'];
      if (value === 'all' || CATEGORIES.includes(value as Category)) {
        this.category = value as Category | 'all';
        this.listLimit = 50;
        this.render();
        this.counts.querySelector<HTMLButtonElement>(`[data-category="${this.category}"]`)?.focus();
      }
    });
    this.list.addEventListener('click', (event) => {
      const button =
        event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-candidate]') : null;
      const candidate = this.visible.find((item) => item.id === button?.dataset['candidate']);
      if (candidate) this.select(candidate);
    });
    this.list.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      const button =
        event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-candidate]') : null;
      const candidate = this.visible.find((item) => item.id === button?.dataset['candidate']);
      if (!candidate) return;
      // Selecting rebuilds the list. Handle activation before replacing the focused
      // button, and prevent a second native click against that detached element.
      event.preventDefault();
      this.select(candidate);
    });
    el('moreCandidates').addEventListener('click', () => {
      this.listLimit += 50;
      this.render();
    });
    el<HTMLFormElement>('prefixForm').addEventListener('submit', (event) => {
      event.preventDefault();
      const data = new FormData(event.currentTarget as HTMLFormElement);
      const input = { prefix: data.get('prefix'), protocol: data.get('protocol') };
      if (data.get('action') === 'ignore') {
        const parsed = IgnoredPrefixSchema.safeParse(input);
        if (!parsed.success) {
          this.ruleStatus('Enter a three-byte prefix, such as B4:1E:52, and a radio type.');
          return;
        }
        if (!this.settings.ignored.some((rule) => JSON.stringify(rule) === JSON.stringify(parsed.data)))
          this.settings.ignored.push(parsed.data);
      } else {
        const parsed = CustomPrefixSchema.safeParse({ ...input, category: data.get('category') });
        if (!parsed.success) {
          this.ruleStatus('Enter a three-byte prefix, such as B4:1E:52, and choose its category and radio type.');
          return;
        }
        if (!this.settings.custom.some((rule) => JSON.stringify(rule) === JSON.stringify(parsed.data)))
          this.settings.custom.push(parsed.data);
      }
      // Keep the same bounds as the imported/persisted configuration.
      if (this.settings.custom.length > 500 || this.settings.ignored.length > 500) {
        this.settings.custom = this.settings.custom.slice(0, 500);
        this.settings.ignored = this.settings.ignored.slice(0, 500);
        this.ruleStatus('A maximum of 500 custom and 500 ignored prefixes can be saved.');
        return;
      }
      this.changedRules('Rule saved. Ignored prefixes take priority.');
    });
    el('savedRules').addEventListener('click', (event) => {
      const button =
        event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-rule-index]') : null;
      if (!button) return;
      const index = Number(button.dataset['ruleIndex']);
      const list = button.dataset['ruleKind'] === 'custom' ? this.settings.custom : this.settings.ignored;
      if (Number.isInteger(index) && index >= 0 && index < list.length) list.splice(index, 1);
      this.changedRules('Rule removed.');
    });
    el('resetRules').addEventListener('click', () => {
      this.settings = emptyRuleSettings();
      this.changedRules('Custom and ignored prefixes cleared. Built-in rules are unchanged.');
    });
    el('exportRules').addEventListener('click', () => {
      const url = URL.createObjectURL(new Blob([JSON.stringify(this.settings, null, 2)], { type: 'application/json' }));
      const link = document.createElement('a');
      link.href = url;
      link.download = 'wardrive-atlas-rules.json';
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    });
    el('importRules').addEventListener('click', () => el<HTMLInputElement>('rulesFile').click());
    el<HTMLInputElement>('rulesFile').addEventListener('change', async (event) => {
      const input = event.currentTarget as HTMLInputElement;
      const file = input.files?.[0];
      if (!file) return;
      try {
        if (file.size > 128_000) throw new Error('Oversized rule file');
        const imported = parseRuleSettings(await file.text());
        // Merge instead of silently deleting rules already configured on this machine.
        const unique = <T>(items: T[]): T[] => [...new Map(items.map((item) => [JSON.stringify(item), item])).values()];
        this.settings = parseRuleSettings(
          JSON.stringify({
            version: 1,
            custom: unique([...this.settings.custom, ...imported.custom]),
            ignored: unique([...this.settings.ignored, ...imported.ignored]),
          }),
        );
        this.changedRules('Rule file imported and merged with your existing rules.');
      } catch {
        this.ruleStatus('This rule file is invalid, unsupported, or too large. Existing rules have not changed.');
      }
      input.value = '';
    });
    this.update([], false);
  }

  private warning(message: string): void {
    const warning = el('notableWarning');
    warning.textContent = message;
    warning.hidden = !message;
  }
  private ruleStatus(message: string): void {
    el('ruleStatus').textContent = message;
  }
  private changedRules(message: string): void {
    const saved = saveRuleSettings(this.storage, this.settings);
    this.warning(saved ? '' : 'Rules are active in this tab but could not be saved. Export them before closing.');
    this.ruleStatus(
      saved ? message : 'Rules applied for this tab only. Browser storage is unavailable; export to save them.',
    );
    this.renderRules();
    this.update(this.records, this.hasData);
  }
  private renderRules(): void {
    const rows = (kind: 'custom' | 'ignored') =>
      this.settings[kind]
        .map(
          (rule, index) =>
            `<li><span><strong>${escape(rule.prefix.match(/../g)!.join(':'))}</strong> · ${escape(rule.protocol)}<small>${'category' in rule ? escape(CATEGORY_LABELS[rule.category]) + ' · user-defined' : 'Ignored · ordinary points remain'}</small></span><button class="text-button small" type="button" data-rule-kind="${kind}" data-rule-index="${index}" aria-label="Remove ${kind} rule ${index + 1}">Remove</button></li>`,
        )
        .join('');
    el('savedRules').innerHTML = rows('custom') + rows('ignored') || '<li>No custom or ignored prefixes.</li>';
    el('catalogVersion').textContent =
      `Built-in catalog ${BUILTIN_CATALOG.version} · reviewed ${BUILTIN_CATALOG.reviewed}`;
  }

  update(records: readonly WardriveRecord[], hasData: boolean): void {
    this.records = records;
    this.hasData = hasData;
    this.candidates = analyzeCandidates(records, this.settings, this.research, this.dismissed);
    this.render();
  }
  clearCapture(): void {
    this.dismissed.clear();
    this.closeSelection();
  }
  pruneDismissals(records: readonly WardriveRecord[]): void {
    const keys = new Set(records.map(candidateKey));
    this.dismissed = new Set([...this.dismissed].filter((key) => keys.has(key)));
  }
  refreshPrivacy(): void {
    this.render();
  }

  private render(): void {
    this.visible = sortCandidates(
      this.candidates.filter((candidate) => this.category === 'all' || candidate.categories.includes(this.category)),
      this.sort,
    );
    this.panel.dataset['hasData'] = String(this.hasData);
    el('notableControls').hidden = !this.hasData;
    this.counts.innerHTML = (['all', ...CATEGORIES] as const)
      .map((category) => {
        const count =
          category === 'all'
            ? this.candidates.length
            : this.candidates.filter((item) => item.categories.includes(category)).length;
        return `<button type="button" data-category="${category}" aria-pressed="${this.category === category}">${category === 'all' ? 'All' : CATEGORY_LABELS[category]} <b>${count}</b></button>`;
      })
      .join('');
    el('notableSummary').textContent = this.hasData
      ? `${this.visible.length.toLocaleString()} observed ${this.visible.length === 1 ? 'address' : 'addresses'} · ${this.visible.reduce((sum, item) => sum + item.representatives.length, 0).toLocaleString()} observation pins`
      : 'Find noteworthy signals in your next import.';
    const empty = !this.hasData
      ? 'Load a CSV or try the sample to explore candidate detections.'
      : !this.records.length
        ? 'No observations match the current filters.'
        : this.candidates.length && !this.visible.length
          ? 'No candidates in this category. Try All.'
          : 'No matching evidence in this CSV view. This does not mean no cameras were present.';
    this.list.innerHTML = this.visible.length
      ? this.visible
          .slice(0, this.listLimit)
          .map((candidate) => {
            const record = candidate.representatives[0]!;
            const label = candidate.categories.map((category) => CATEGORY_LABELS[category]).join(' / ');
            return `<li><button class="candidate-row${candidate.weak ? ' weak' : ''}" type="button" data-candidate="${candidate.id}" aria-pressed="${candidate.key === this.selectedKey}"><span class="candidate-symbol" aria-hidden="true">${candidate.categories.length > 1 ? '+' : candidate.categories[0] === 'flock' ? 'F' : candidate.categories[0] === 'axon' ? 'A' : 'M'}</span><span class="candidate-copy"><strong>${escape(label)} candidate</strong><span>${escape(this.host.name(record))}</span><span class="candidate-address">${escape(this.host.address(record))} · ${escape(record.type)}</span><small>${escape(evidenceLabel(candidate.evidence[0]!))} · ${candidate.records.length} ${candidate.records.length === 1 ? 'sighting' : 'sightings'}</small></span><span class="candidate-signal">${candidate.strongest ?? '—'}<small>dBm</small></span></button></li>`;
          })
          .join('')
      : `<li class="notable-empty">${empty}</li>`;
    el('moreCandidates').hidden = this.visible.length <= this.listLimit;
    const restore = el<HTMLButtonElement>('restoreCandidates');
    restore.hidden = !this.dismissed.size;
    restore.textContent = `Restore dismissed (${this.dismissed.size})`;
    const missing = this.records.filter((record) => record.type === 'BLE' && record.manufacturerId === null).length;
    el('notableCoverage').textContent = this.hasData
      ? `${missing.toLocaleString()} Bluetooth observations lack a usable manufacturer ID. CSV has no probe behavior, advertisement payload, or saved Biscuit detection methods; counts may differ from Biscuit.`
      : 'Analysis runs on this device. Pins mark where you observed a signal, not where a camera is installed.';
    const selected = this.visible.find((candidate) => candidate.key === this.selectedKey);
    if (selected) this.renderDetail(selected);
    else this.closeSelection();
    this.syncMap();
  }

  private select(candidate: Candidate): void {
    this.host.onSelect();
    this.selectedKey = candidate.key;
    this.render();
    this.host.fit(candidate.records);
    this.list.querySelector<HTMLButtonElement>(`[data-candidate="${candidate.id}"]`)?.focus({ preventScroll: true });
    if (window.innerWidth <= 820) el('mapCanvas').scrollIntoView({ behavior: 'instant', block: 'start' });
  }
  closeSelection(): void {
    this.selectedKey = null;
    this.detail.hidden = true;
    el('notableDetailName').textContent = '';
    el('notableDetailList').replaceChildren();
    el('notableEvidence').replaceChildren();
    el('notableSessions').textContent = '';
    this.list
      .querySelectorAll('[aria-pressed="true"]')
      .forEach((button) => button.setAttribute('aria-pressed', 'false'));
    this.syncMap();
  }
  private renderDetail(candidate: Candidate): void {
    const record = candidate.representatives[0]!;
    el('notableDetailType').textContent =
      `${candidate.categories.map((category) => CATEGORY_LABELS[category]).join(' / ')} candidate${candidate.weak ? ' · research lead' : ''}`;
    el('notableDetailName').textContent = this.host.name(record);
    const entries = [
      ['Address', this.host.address(record)],
      ['Radio', record.type],
      ['Sightings', String(candidate.records.length)],
      ['Sessions', String(candidate.representatives.length)],
      ['First seen', time(candidate.firstSeen)],
      ['Last seen', time(candidate.lastSeen)],
      ['Strongest signal', signal(candidate.strongest)],
      ['Observed here', `${record.latitude.toFixed(6)}, ${record.longitude.toFixed(6)}`],
    ];
    el('notableDetailList').innerHTML = entries
      .map(([key, value]) => `<div><dt>${key}</dt><dd>${escape(value!)}</dd></div>`)
      .join('');
    el('notableEvidence').innerHTML = candidate.evidence
      .map(
        (rule) =>
          `<li><span class="evidence-badge${rule.research ? ' research' : ''}">${escape(evidenceLabel(rule))}</span><p>${escape(rule.explanation)}</p>${rule.source ? `<a href="${escape(rule.source)}" target="_blank" rel="noopener noreferrer">${escape(rule.sourceLabel)} ↗</a>` : '<span>Your custom rule</span>'}</li>`,
      )
      .join('');
    el('notableSessions').textContent = candidate.representatives.map((item) => item.session).join(' · ');
    this.detail.hidden = false;
  }

  addMapLayers(): void {
    const map = this.host.map;
    addNotableIcons(map);
    map.addSource(SIGHTINGS_SOURCE, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map.addLayer({
      id: 'notable-sighting-halos',
      type: 'circle',
      source: SIGHTINGS_SOURCE,
      paint: {
        'circle-radius': 8,
        'circle-color': '#172a46',
        'circle-opacity': 0.65,
        'circle-stroke-color': '#ffffff',
        'circle-stroke-width': 2,
      },
    });
    map.addSource(NOTABLE_SOURCE, { type: 'geojson', data: candidateFeatures(this.visible) });
    map.addLayer({
      id: NOTABLE_PINS,
      type: 'symbol',
      source: NOTABLE_SOURCE,
      layout: {
        'icon-image': ['get', 'icon'],
        'icon-size': 0.85,
        'icon-anchor': 'bottom',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
      },
    });
    this.syncMap();
  }
  private syncMap(): void {
    const map = this.host.map;
    const pins = map.getSource(NOTABLE_SOURCE) as GeoJSONSource | undefined;
    if (pins) pins.setData(candidateFeatures(this.visible));
    const selected = this.visible.find((candidate) => candidate.key === this.selectedKey);
    const sightings = map.getSource(SIGHTINGS_SOURCE) as GeoJSONSource | undefined;
    if (sightings)
      sightings.setData({
        type: 'FeatureCollection',
        features: (selected?.records ?? []).map((record) => ({
          type: 'Feature',
          properties: {},
          geometry: { type: 'Point', coordinates: [record.longitude, record.latitude] },
        })),
      });
  }
  handleMapClick(point: PointLike): boolean {
    if (!this.host.map.getLayer(NOTABLE_PINS)) return false;
    const feature = this.host.map.queryRenderedFeatures(point, { layers: [NOTABLE_PINS] })[0];
    const candidate = this.visible.find((item) => item.id === feature?.properties?.['candidateId']);
    if (!candidate) return false;
    this.select(candidate);
    return true;
  }
}
