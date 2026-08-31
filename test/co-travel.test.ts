import { afterEach, describe, expect, it, vi } from 'vitest';
import { WardriveRecordSchema, type WardriveRecord } from '../src/csv';
import {
  analyzeCoTravel,
  assessmentView,
  compareWindows,
  distanceMeters,
  exclusionReason,
  independentSightings,
  qualifiesWindow,
} from '../src/co-travel';
import {
  CoTravelRequestSchema,
  CoTravelResponseSchema,
  CoTravelSettingsSchema,
  THRESHOLDS,
  emptyCoTravelAnalysis,
  type CoTravelRequest,
  type EvidenceWindow,
  type Sensitivity,
} from '../src/co-travel-schema';
import {
  identityDigest,
  loadTrustedDevices,
  TrustStateController,
  TRUST_KEY,
  TrustedSettingsSchema,
} from '../src/co-travel-trust';
import { CoTravelRunner, type AnalysisWorker } from '../src/co-travel-runner';
import { movementPins, movementSelection } from '../src/co-travel-map';

const START = Date.UTC(2026, 7, 30, 12);
const EARTH = 6_371_000;
// Synthetic receiver positions along a meridian; meter offsets are exact arc distances.
function row(minute: number, offset: number, changes: Partial<WardriveRecord> = {}): WardriveRecord {
  return WardriveRecordSchema.parse({
    id: `row-${minute}-${offset}`,
    session: 'synthetic-drive.csv',
    bssid: 'DA:10:20:30:40:50',
    ssid: 'Synthetic shared-route companion',
    authMode: 'Unknown',
    security: 'Other',
    firstSeen: new Date(START + minute * 60_000).toISOString(),
    timestamp: START + minute * 60_000,
    channel: 0,
    band: 'Bluetooth',
    rssi: -60,
    latitude: 42 + ((offset / EARTH) * 180) / Math.PI,
    longitude: -71,
    altitude: null,
    accuracy: 5,
    type: 'BLE',
    ...changes,
  });
}
const drive = (): WardriveRecord[] => [row(0, 0), row(5, 350), row(10, 700)];
const assess = (records = drive(), sensitivity: Sensitivity = 'medium') =>
  analyzeCoTravel(records, sensitivity).assessments[0]!;

describe('movement evidence and thresholds', () => {
  it('defaults to Medium and validates sensitivity settings', () => {
    expect(CoTravelSettingsSchema.parse({})).toEqual({ sensitivity: 'medium' });
    expect(CoTravelSettingsSchema.safeParse({ sensitivity: 'extreme' }).success).toBe(false);
  });
  it.each(['high', 'medium', 'low'] as const)(
    'includes every %s threshold boundary and rejects each shortfall',
    (sensitivity) => {
      const t = THRESHOLDS[sensitivity];
      expect(qualifiesWindow(t.sightings, t.locations, t.minutes * 60_000, t.meters, sensitivity)).toBe(true);
      expect(qualifiesWindow(t.sightings - 1, t.locations, t.minutes * 60_000, t.meters, sensitivity)).toBe(false);
      expect(qualifiesWindow(t.sightings, t.locations - 1, t.minutes * 60_000, t.meters, sensitivity)).toBe(false);
      expect(qualifiesWindow(t.sightings, t.locations, t.minutes * 60_000 - 1, t.meters, sensitivity)).toBe(false);
      expect(qualifiesWindow(t.sightings, t.locations, t.minutes * 60_000, t.meters - 0.01, sensitivity)).toBe(false);
      const rows = Array.from({ length: t.sightings }, (_, index) =>
        row((index * t.minutes) / (t.sightings - 1), (index * (t.meters + 10)) / (t.sightings - 1)),
      );
      expect(assess(rows, sensitivity).window?.qualifies).toBe(true);
    },
  );
  it('treats plausible shared-route coincidences as candidates, not verified following', () => {
    const result = assess();
    expect(result.window).toMatchObject({ qualifies: true, locations: 3, travelMeters: expect.closeTo(690, 5) });
    expect(assessmentView(result, false)).toBe('candidates');
    expect(Object.keys(result)).not.toContain('threatProbability');
  });
  it('does not accumulate stationary repeats, GPS jitter, or out-and-back path length', () => {
    expect(assess([row(0, 0), row(5, 50), row(10, -50), row(20, 0)]).window?.qualifies).toBe(false);
    const result = assess([row(0, 0), row(5, 300), row(10, 0), row(20, 300)]);
    expect(result.window?.travelMeters).toBeCloseTo(290);
    expect(result.window?.qualifies).toBe(false);
    expect(assess([row(0, 0), row(10, 0)]).window?.travelMeters).toBe(0);
  });
  it('subtracts both accuracy radii and never uses signal as distance', () => {
    const records = [
      row(0, 0, { accuracy: 75, rssi: -20 }),
      row(5, 300, { accuracy: 75, rssi: -127 }),
      row(10, 600, { accuracy: 75 }),
    ];
    expect(assess(records).window?.travelMeters).toBeCloseTo(450);
    expect(assess(records).window?.qualifies).toBe(false);
    expect(assess(drive().map((record) => ({ ...record, rssi: null }))).window?.qualifies).toBe(true);
  });
  it('uses immutable chronological anchors, never transitive chaining', () => {
    const sightings = independentSightings([row(0, 0), row(1, 150), row(2, 300), row(3, 450), row(4, 600)]);
    expect(sightings.map((item) => item.location)).toEqual([0, 0, 1, 1, 2]);
    expect(independentSightings([row(0, 0), row(1, 200), row(2, 200.01)]).map((item) => item.location)).toEqual([
      0, 0, 1,
    ]);
  });
  it('deduplicates clock minutes across files using accuracy, time, then coordinates', () => {
    const records = [
      row(0.9, 100, { accuracy: 6 }),
      row(0.8, 200, { accuracy: 5 }),
      row(0.7, 300, { accuracy: 5 }),
      row(0.7, 150, { accuracy: 5 }),
      row(1, 400),
      row(0.7, 150, { accuracy: 5, id: 'duplicate', session: 'overlap.csv' }),
    ];
    const result = analyzeCoTravel(records);
    expect(result.coverage).toMatchObject({ eligible: 6, independent: 2, duplicates: 4 });
    expect(result.assessments[0]!.sightings[0]!.recordId).toBe('duplicate');
    // Best accuracy outranks an earlier time, even when files overlap.
    expect(
      independentSightings([row(0.1, 0, { accuracy: 50 }), row(0.9, 400, { accuracy: 5 })])[0]!.record.latitude,
    ).toBe(row(0.9, 400).latitude);
  });
  it('is invariant to shuffled rows and normalized address formatting', () => {
    const records = drive().map((record, index) => ({
      ...record,
      bssid: ['da-10-20-30-40-50', 'DA10.2030.4050', 'DA1020304050'][index]!,
    }));
    expect(assess([...records].reverse())).toEqual(assess(records));
    expect(assess(records).recordIds).toHaveLength(3);
  });
  it('never joins rotating addresses, Wi-Fi/BLE, names, prefixes or signal similarity', () => {
    const records = drive().map((record, index) => ({ ...record, bssid: `DA:10:20:30:40:5${index}` }));
    expect(analyzeCoTravel(records).assessments).toHaveLength(3);
    expect(analyzeCoTravel(records).assessments.every((item) => !item.window?.qualifies)).toBe(true);
    expect(
      analyzeCoTravel([
        ...drive(),
        ...drive().map((record) => ({ ...record, id: 'wifi-' + record.id, type: 'Wi-Fi' as const })),
      ]).assessments,
    ).toHaveLength(2);
  });
  it('retains excluded observations and explains disjoint coverage counts', () => {
    const bad: Array<Partial<WardriveRecord>> = [
      { accuracy: null },
      { accuracy: 0 },
      { accuracy: 75.01 },
      { timestamp: null },
      { bssid: 'not-an-address' },
      { latitude: 0, longitude: 0 },
    ];
    const records = bad.map((changes, index) => row(index, 0, { id: `bad-${index}`, ...changes }));
    const result = analyzeCoTravel([...records, row(15, 0, { accuracy: 75 })]);
    expect(result.coverage).toMatchObject({
      total: 7,
      eligible: 1,
      excluded: 6,
      invalidAddress: 1,
      invalidTime: 1,
      invalidFix: 1,
      invalidAccuracy: 3,
    });
    expect(result.assessments.reduce((sum, item) => sum + item.recordIds.length, 0)).toBe(7);
    expect(exclusionReason({ ...row(0, 0), timestamp: NaN })).toBe('invalidTime');
    expect(exclusionReason({ ...row(0, 0), latitude: 91 })).toBe('invalidFix');
    expect(exclusionReason({ ...row(0, 0), accuracy: -1 })).toBe('invalidAccuracy');
  });
  it('keeps Wi-Fi and Flock/Axon signatures in context even when moving', () => {
    for (const changes of [
      { type: 'Wi-Fi' as const },
      { manufacturerId: '09C8' },
      { manufacturerId: '034D' },
      { ssid: 'Penguin-SYNTHETIC' },
      { bssid: '00:25:DF:00:00:01' },
    ]) {
      const result = assess(drive().map((record) => ({ ...record, ...changes })));
      expect(assessmentView(result, false)).toBe('context');
      expect(result.window?.qualifies).toBe(false);
    }
    expect(assess(drive().map((record) => ({ ...record, ssid: 'Ray-Ban SYNTHETIC' }))).window?.qualifies).toBe(true);
    expect(assessmentView(assess(drive().map((record) => ({ ...record, accuracy: null }))), false)).toBe('observed');
  });
  it('uses custom camera context without treating notable ignore rules as trust', () => {
    const result = analyzeCoTravel(drive(), 'medium', [{ prefix: 'DA1020', category: 'axon', protocol: 'BLE' }]);
    expect(result.assessments[0]!.contextLabels).toEqual(['axon']);
    expect(assessmentView(result.assessments[0]!, false)).toBe('context');
    // Prefix ignores are intentionally not an input to the movement engine.
    expect(assessmentView(assess(), false)).toBe('candidates');
  });
});

describe('selected-range and rolling-window evidence', () => {
  it('qualifies across selected files and collapses overlapping imports', () => {
    const records = drive().map((record, index) => ({ ...record, session: index ? 'second.csv' : 'first.csv' }));
    const result = assess([
      ...records,
      ...records.map((record) => ({ ...record, id: `copy-${record.id}`, session: 'overlap.csv' })),
    ]);
    expect(result.window?.qualifies).toBe(true);
    expect(result.recordIds).toHaveLength(6);
    expect(result.sightings).toHaveLength(3);
    expect(result.sessions).toBe(3);
    expect(assess(records.filter((record) => record.session === 'second.csv')).window?.qualifies).toBe(false);
    expect(analyzeCoTravel([]).assessments).toEqual([]);
    expect(assess(records.filter((record) => record.timestamp! < START + 10 * 60_000)).window?.qualifies).toBe(false);
  });
  it('includes exactly 12 hours and rejects evidence spread beyond it', () => {
    expect(assess([row(0, 0), row(5, 350), row(720, 700)]).window?.qualifies).toBe(true);
    const result = assess([row(0, 0), row(5, 350), row(721, 700)]);
    expect(result.window?.qualifies).toBe(false);
    expect(result.recordIds).toHaveLength(3);
    expect(result.sightings).toHaveLength(3);
    expect(result.window!.sightingIds.length).toBeLessThan(3);
  });
  it('does not combine thresholds from different windows', () => {
    const result = assess([row(0, 0), row(1, 800), row(2, 1600), row(1000, 0), row(1010, 0), row(1020, 0)]);
    expect(result.window?.qualifies).toBe(false);
  });
  it('chooses a qualifying window before one with more locations', () => {
    const result = assess([...drive(), row(1000, 0), row(1001, 400), row(1002, 800), row(1003, 1200)]);
    expect(result.window?.qualifies).toBe(true);
    expect(result.window?.last).toBe(START + 10 * 60_000);
    expect(result.sightings).toHaveLength(7);
  });
  it('ranks windows by locations, sightings, travel, then recency', () => {
    const window: EvidenceWindow = {
      first: 0,
      last: 10,
      sightingIds: ['1', '2', '3'],
      locations: 2,
      travelMeters: 600,
      qualifies: true,
    };
    for (const better of [{ locations: 3 }, { sightingIds: ['1', '2', '3', '4'] }, { travelMeters: 601 }, { last: 11 }])
      expect(compareWindows({ ...window, ...better }, window)).toBeLessThan(0);
    expect(compareWindows(window, { ...window, qualifies: false, locations: 100 })).toBeLessThan(0);
    expect(compareWindows(null, window)).toBeGreaterThan(0);
  });
  it('expires old separation pairs when sliding beyond twelve hours', () => {
    const result = assess([row(0, -100000), row(710, 0), row(720, 350), row(721, 700), row(730, 1050)]);
    // Later four-sighting, four-location window wins; its travel span cannot retain the old outlier.
    expect(result.window?.first).toBe(START + 710 * 60_000);
    expect(result.window?.travelMeters).toBeCloseTo(1040);
  });
  it('matches a brute-force window oracle on a long shuffled synthetic drive', () => {
    const records = Array.from({ length: 150 }, (_, index) =>
      row(index * 11, Math.sin(index * 1.7) * 900 + index * 3, { accuracy: 1 + (index % 75) }),
    );
    const sightings = independentSightings(records);
    let best: EvidenceWindow | null = null;
    for (let end = 0; end < sightings.length; end++) {
      const active = sightings
        .slice(0, end + 1)
        .filter((item) => sightings[end]!.record.timestamp - item.record.timestamp <= 720 * 60_000);
      let travel = 0;
      for (const a of active)
        for (const b of active)
          travel = Math.max(travel, distanceMeters(a.record, b.record) - a.record.accuracy - b.record.accuracy);
      const first = active[0]!.record.timestamp,
        last = active.at(-1)!.record.timestamp;
      const locations = new Set(active.map((item) => item.location)).size;
      const window = {
        first,
        last,
        locations,
        sightingIds: active.map((item) => item.record.id),
        travelMeters: travel,
        qualifies: qualifiesWindow(active.length, locations, last - first, travel, 'medium'),
      };
      if (compareWindows(window, best) < 0) best = window;
    }
    expect(assess([...records].reverse()).window).toEqual(best);
  });
});

describe('trusted devices', () => {
  const storage = () => {
    const data = new Map<string, string>();
    return {
      data,
      getItem: (key: string) => data.get(key) ?? null,
      setItem: (key: string, value: string) => {
        data.set(key, value);
      },
    };
  };
  it('stores full, normalized, radio-separated SHA-256 digests only', async () => {
    const a = await identityDigest(row(0, 0));
    expect(a).toMatch(/^[a-f0-9]{64}$/);
    expect(await identityDigest(row(0, 0, { bssid: 'da10.2030.4050' }))).toBe(a);
    expect(await identityDigest(row(0, 0, { type: 'Wi-Fi' }))).not.toBe(a);
    expect(await identityDigest(row(0, 0, { bssid: 'invalid' }))).toBeNull();
    const store = storage();
    const settings = { version: 1 as const, devices: [{ digest: a!, type: 'BLE' as const }] };
    const trust = new TrustStateController({ storage: store, lock: { run: async (_, operation) => operation() } });
    expect(await trust.mutate({ action: 'trust', device: settings.devices[0] })).toBe('saved');
    expect(loadTrustedDevices(store).settings).toEqual(settings);
    expect([...store.data.keys()]).toEqual([TRUST_KEY]);
    expect(store.data.get(TRUST_KEY)).not.toMatch(/ssid|latitude|longitude|DA:10|Synthetic|session/i);
    expect(
      TrustedSettingsSchema.safeParse({ ...settings, devices: [{ ...settings.devices[0], name: 'private' }] }).success,
    ).toBe(false);
  });
  it.each(['not json', '{"version":2,"devices":[]}', '{"version":1,"devices":[{"digest":"short","type":"BLE"}]}'])(
    'recovers visibly from invalid saved settings: %s',
    (value) => {
      const store = storage();
      store.setItem(TRUST_KEY, value);
      expect(loadTrustedDevices(store)).toMatchObject({ settings: { devices: [] }, warning: expect.any(String) });
    },
  );
  it('handles storage denial and restores trusted vehicle equipment eligibility without deleting evidence', async () => {
    const store = {
      getItem: () => {
        throw new Error();
      },
      setItem: () => {
        throw new Error();
      },
    };
    expect(loadTrustedDevices(store).warning).toBeTruthy();
    const trust = new TrustStateController({ storage: store, lock: { run: async (_, operation) => operation() } });
    expect(await trust.mutate({ action: 'trust', device: { digest: 'a'.repeat(64), type: 'BLE' } })).toBe('tab-only');
    const vehicle = assess(drive().map((record) => ({ ...record, ssid: 'Synthetic vehicle equipment' })));
    expect(assessmentView(vehicle, true)).toBe('trusted');
    expect(assessmentView(vehicle, false)).toBe('candidates');
    expect(vehicle.sightings).toHaveLength(3);
  });
  it('rejects duplicate trust entries without treating them as two devices', () => {
    const entry = { digest: 'a'.repeat(64), type: 'BLE' };
    expect(TrustedSettingsSchema.safeParse({ version: 1, devices: [entry, entry] }).success).toBe(false);
  });
});

describe('local worker boundaries and cancellation', () => {
  afterEach(() => vi.unstubAllGlobals());
  const input = { records: drive(), settings: { sensitivity: 'medium' as const }, customPrefixes: [] };
  it('validates requests and rejects malformed results', () => {
    expect(CoTravelRequestSchema.safeParse({ ...input, requestId: 1 }).success).toBe(true);
    expect(CoTravelRequestSchema.safeParse({ ...input, requestId: 1, records: [{ fake: 'row' }] }).success).toBe(false);
    expect(
      CoTravelResponseSchema.safeParse({ kind: 'result', requestId: 1, result: { assessments: [], coverage: {} } })
        .success,
    ).toBe(false);
  });
  it('validates the worker entry point itself and returns only typed evidence', async () => {
    const scope: { onmessage: ((event: MessageEvent) => void) | null; postMessage: ReturnType<typeof vi.fn> } = {
      onmessage: null,
      postMessage: vi.fn(),
    };
    vi.stubGlobal('self', scope);
    await import('../src/co-travel-worker');
    scope.onmessage!({ data: { ...input, requestId: 14 } } as MessageEvent);
    const response = CoTravelResponseSchema.parse(scope.postMessage.mock.calls[0]![0]);
    expect(response.kind).toBe('result');
    if (response.kind === 'result') expect(response.result.assessments[0]!.window?.qualifies).toBe(true);
    scope.onmessage!({ data: { requestId: 15, records: 'invalid' } } as MessageEvent);
    expect(scope.postMessage.mock.calls[1]![0]).toMatchObject({ kind: 'error', requestId: 0 });
  });
  it('terminates superseded workers and ignores late queued responses', () => {
    const workers: Array<AnalysisWorker & { message?: CoTravelRequest }> = [];
    const runner = new CoTravelRunner(() => {
      const worker: AnalysisWorker & { message?: CoTravelRequest } = {
        onmessage: null,
        onerror: null,
        postMessage: (message) => {
          worker.message = message;
        },
        terminate: vi.fn(),
      };
      workers.push(worker);
      return worker;
    });
    const onResult = vi.fn(),
      onError = vi.fn();
    runner.run(input, onResult, onError);
    const stale = workers[0]!.onmessage!;
    runner.run(input, onResult, onError);
    expect(workers[0]!.terminate).toHaveBeenCalledOnce();
    stale({
      data: { kind: 'result', requestId: workers[0]!.message!.requestId, result: emptyCoTravelAnalysis() },
    } as MessageEvent);
    expect(onResult).not.toHaveBeenCalled();
    workers[1]!.onmessage!({
      data: { kind: 'result', requestId: workers[1]!.message!.requestId, result: analyzeCoTravel(drive()) },
    } as MessageEvent);
    expect(onResult).toHaveBeenCalledOnce();
    expect(onError).not.toHaveBeenCalled();
    runner.cancel();
  });
  it('fails safely on invalid responses, startup failures and worker errors', () => {
    const worker: AnalysisWorker = { onmessage: null, onerror: null, postMessage: vi.fn(), terminate: vi.fn() };
    const error = vi.fn(),
      result = vi.fn();
    const runner = new CoTravelRunner(() => worker);
    runner.run(input, result, error);
    worker.onmessage!({ data: { kind: 'result', requestId: 0, result: emptyCoTravelAnalysis() } } as MessageEvent);
    expect(error).toHaveBeenCalledOnce();
    expect(result).not.toHaveBeenCalled();
    runner.run(input, result, error);
    worker.onerror!({} as ErrorEvent);
    expect(error).toHaveBeenCalledTimes(2);
    new CoTravelRunner(() => {
      throw new Error('startup');
    }).run(input, result, error);
    expect(error).toHaveBeenCalledTimes(3);
  });
});

describe('identifier-free movement map projections', () => {
  it('pins one independent position per session and highlights all filtered observations', () => {
    const records = drive().map((record, index) => ({ ...record, session: index ? 'second.csv' : 'first.csv' }));
    const assessment = assess(records);
    const byId = new Map(records.map((record) => [record.id, record]));
    const pins = movementPins([assessment], byId);
    expect(pins.features).toHaveLength(2);
    expect(pins.features[1]!.geometry.coordinates).toEqual([records[2]!.longitude, records[2]!.latitude]);
    const selection = movementSelection(assessment, byId);
    expect(selection.points.features).toHaveLength(3);
    expect(selection.paths.features).toHaveLength(1);
    expect(selection.paths.features[0]!.geometry.coordinates).toHaveLength(2);
    expect(
      JSON.stringify(
        [...pins.features, ...selection.points.features, ...selection.paths.features].map(
          (feature) => feature.properties,
        ),
      ),
    ).not.toMatch(/DA:10|Synthetic|"session"|ssid|bssid|digest|\.csv/);
  });
  it('breaks receiver paths above five minutes, never between sessions, and keeps exclusions off paths', () => {
    const records = [
      row(0, 0),
      row(5, 350),
      row(10.01, 700),
      row(15.01, 1050),
      row(20, 1400, { accuracy: null }),
      row(21, 1500, { session: 'other.csv' }),
    ];
    const byId = new Map(records.map((record) => [record.id, record]));
    const selection = movementSelection(assess(records), byId);
    expect(selection.points.features).toHaveLength(6);
    expect(selection.paths.features.map((feature) => feature.geometry.coordinates.length)).toEqual([2, 2]);
    expect(movementSelection(undefined, byId).points.features).toHaveLength(0);
    expect(movementPins([], byId).features).toHaveLength(0);
  });
});
