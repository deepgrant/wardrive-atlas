import type { WardriveRecord } from './csv';
import {
  candidateKey,
  compileRules,
  emptyRuleSettings,
  matchRecord,
  normalizeAddress,
  type RuleSettings,
} from './notable';
import {
  emptyCoTravelAnalysis,
  THRESHOLDS,
  type CoTravelAnalysis,
  type CoTravelAssessment,
  type EvidenceWindow,
  type Sensitivity,
} from './co-travel-schema';

const EARTH_METERS = 6_371_000;
const WINDOW_MS = 12 * 60 * 60 * 1000;
export const PATH_GAP_MS = 5 * 60 * 1000;
const radians = (degrees: number): number => (degrees * Math.PI) / 180;

export function distanceMeters(
  a: Pick<WardriveRecord, 'latitude' | 'longitude'>,
  b: Pick<WardriveRecord, 'latitude' | 'longitude'>,
): number {
  const h =
    Math.sin(radians(b.latitude - a.latitude) / 2) ** 2 +
    Math.cos(radians(a.latitude)) *
      Math.cos(radians(b.latitude)) *
      Math.sin(radians(b.longitude - a.longitude) / 2) ** 2;
  return 2 * EARTH_METERS * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
}

export function qualifiesWindow(
  sightings: number,
  locations: number,
  elapsedMs: number,
  travelMeters: number,
  sensitivity: Sensitivity,
): boolean {
  const threshold = THRESHOLDS[sensitivity];
  return (
    sightings >= threshold.sightings &&
    locations >= threshold.locations &&
    elapsedMs >= threshold.minutes * 60_000 &&
    travelMeters + 1e-6 >= threshold.meters
  );
}

type Sighting = { record: WardriveRecord & { timestamp: number; accuracy: number }; location: number };

function stableOrder(a: WardriveRecord, b: WardriveRecord): number {
  return (
    (a.timestamp ?? Infinity) - (b.timestamp ?? Infinity) ||
    a.latitude - b.latitude ||
    a.longitude - b.longitude ||
    a.session.localeCompare(b.session) ||
    a.id.localeCompare(b.id)
  );
}

// Cartesian cells avoid longitude/pole discontinuities and bound anchor searches.
function cell(record: WardriveRecord): [number, number, number] {
  const lat = radians(record.latitude),
    lng = radians(record.longitude);
  return [
    Math.floor((EARTH_METERS * Math.cos(lat) * Math.cos(lng)) / 200),
    Math.floor((EARTH_METERS * Math.cos(lat) * Math.sin(lng)) / 200),
    Math.floor((EARTH_METERS * Math.sin(lat)) / 200),
  ];
}

export function independentSightings(records: readonly WardriveRecord[]): Sighting[] {
  const minutes = new Map<number, Sighting['record']>();
  for (const raw of records) {
    const record = raw as Sighting['record']; // Caller has already checked eligibility.
    const minute = Math.floor(record.timestamp / 60_000);
    const existing = minutes.get(minute);
    if (
      !existing ||
      record.accuracy < existing.accuracy ||
      (record.accuracy === existing.accuracy && stableOrder(record, existing) < 0)
    )
      minutes.set(minute, record);
  }
  const anchors: WardriveRecord[] = [];
  const cells = new Map<string, number[]>();
  return [...minutes.values()].sort(stableOrder).map((record) => {
    const [x, y, z] = cell(record);
    let location = Infinity;
    for (let dx = -1; dx <= 1; dx++)
      for (let dy = -1; dy <= 1; dy++)
        for (let dz = -1; dz <= 1; dz++) {
          for (const index of cells.get(`${x + dx},${y + dy},${z + dz}`) ?? []) {
            if (index < location && distanceMeters(anchors[index]!, record) <= 200 + 1e-6) location = index;
          }
        }
    if (!Number.isFinite(location)) {
      location = anchors.length;
      anchors.push(record); // Fixed first-observation anchor, never a moving centroid.
      const key = `${x},${y},${z}`;
      const bucket = cells.get(key) ?? [];
      bucket.push(location);
      cells.set(key, bucket);
    }
    return { record, location };
  });
}

export function compareWindows(a: EvidenceWindow | null, b: EvidenceWindow | null): number {
  if (!a || !b) return a ? -1 : b ? 1 : 0;
  return (
    Number(b.qualifies) - Number(a.qualifies) ||
    b.locations - a.locations ||
    b.sightingIds.length - a.sightingIds.length ||
    b.travelMeters - a.travelMeters ||
    b.last - a.last
  );
}

function strongestWindow(sightings: readonly Sighting[], sensitivity: Sensitivity): EvidenceWindow | null {
  if (!sightings.length) return null;
  const maxima = new Float64Array(sightings.length);
  const locations = new Map<number, number>();
  let start = 0;
  let best: (Omit<EvidenceWindow, 'sightingIds'> & { start: number; end: number }) | null = null;
  for (let end = 0; end < sightings.length; end++) {
    const latest = sightings[end]!;
    while (latest.record.timestamp - sightings[start]!.record.timestamp > WINDOW_MS) {
      const location = sightings[start++]!.location;
      const count = locations.get(location)! - 1;
      if (count === 0) locations.delete(location);
      else locations.set(location, count);
    }
    locations.set(latest.location, (locations.get(latest.location) ?? 0) + 1);
    let travelMeters = 0;
    // Each row retains its greatest separation to later rows. Once it expires,
    // all pairs involving it expire together. <=721 minute buckets per window:
    // O(n * 721) time, O(n) memory, without enumerating all window pairs again.
    for (let index = start; index < end; index++) {
      const previous = sightings[index]!.record;
      maxima[index] = Math.max(
        maxima[index]!,
        distanceMeters(previous, latest.record) - previous.accuracy - latest.record.accuracy,
      );
      travelMeters = Math.max(travelMeters, maxima[index]!);
    }
    const first = sightings[start]!.record.timestamp;
    const current = {
      start,
      end,
      first,
      last: latest.record.timestamp,
      locations: locations.size,
      travelMeters,
      qualifies: qualifiesWindow(
        end - start + 1,
        locations.size,
        latest.record.timestamp - first,
        travelMeters,
        sensitivity,
      ),
    };
    if (
      !best ||
      Number(current.qualifies) > Number(best.qualifies) ||
      (current.qualifies === best.qualifies &&
        (current.locations > best.locations ||
          (current.locations === best.locations &&
            (current.end - current.start > best.end - best.start ||
              (current.end - current.start === best.end - best.start &&
                (current.travelMeters > best.travelMeters ||
                  (current.travelMeters === best.travelMeters && current.last > best.last)))))))
    )
      best = current;
  }
  if (!best) return null;
  const { start: firstIndex, end: lastIndex, ...window } = best;
  return { ...window, sightingIds: sightings.slice(firstIndex, lastIndex + 1).map((item) => item.record.id) };
}

export type Exclusion = 'invalidAddress' | 'invalidTime' | 'invalidFix' | 'invalidAccuracy';
export function usablePosition(record: Pick<WardriveRecord, 'latitude' | 'longitude'>): boolean {
  return (
    Number.isFinite(record.latitude) &&
    Number.isFinite(record.longitude) &&
    Math.abs(record.latitude) <= 90 &&
    Math.abs(record.longitude) <= 180 &&
    (record.latitude !== 0 || record.longitude !== 0)
  );
}
export function exclusionReason(record: WardriveRecord): Exclusion | null {
  if (!normalizeAddress(record.bssid)) return 'invalidAddress';
  if (record.timestamp === null || !Number.isFinite(record.timestamp)) return 'invalidTime';
  if (!usablePosition(record)) return 'invalidFix';
  if (record.accuracy === null || !Number.isFinite(record.accuracy) || record.accuracy <= 0 || record.accuracy > 75)
    return 'invalidAccuracy';
  return null;
}

export function analyzeCoTravel(
  records: readonly WardriveRecord[],
  sensitivity: Sensitivity = 'medium',
  customPrefixes: RuleSettings['custom'] = [],
): CoTravelAnalysis {
  const result = emptyCoTravelAnalysis();
  result.coverage.total = records.length;
  result.coverage.sessions = new Set(records.map((record) => record.session)).size;
  const groups = new Map<
    string,
    { all: WardriveRecord[]; eligible: WardriveRecord[]; cameras: Set<'flock' | 'axon'> }
  >();
  const settings = { ...emptyRuleSettings(), custom: customPrefixes };
  const rules = compileRules(settings).filter(
    (rule) => !rule.research && (rule.category === 'flock' || rule.category === 'axon'),
  );
  for (const record of records) {
    const key = candidateKey(record);
    let group = groups.get(key);
    if (!group) {
      group = { all: [], eligible: [], cameras: new Set() };
      groups.set(key, group);
    }
    group.all.push(record);
    for (const rule of matchRecord(record, rules, settings))
      if (rule.category === 'flock' || rule.category === 'axon') group.cameras.add(rule.category);
    const reason = exclusionReason(record);
    if (reason) {
      result.coverage[reason]++;
      result.coverage.excluded++;
    } else {
      group.eligible.push(record);
      result.coverage.eligible++;
    }
  }
  for (const group of groups.values()) {
    const sightings = independentSightings(group.eligible);
    const ordered = [...group.all].sort(stableOrder);
    const representative = sightings.at(-1)?.record ?? ordered[0]!;
    const locations = new Set(sightings.map((item) => item.location)).size;
    const context = representative.type === 'Wi-Fi' ? 'wifi' : group.cameras.size ? 'camera' : null;
    const window = strongestWindow(sightings, sensitivity);
    // Context may meet geometric thresholds but can never become a movement candidate.
    if (context && window) window.qualifies = false;
    result.assessments.push({
      id: `movement-${result.assessments.length}`,
      representativeId: representative.id,
      type: representative.type,
      recordIds: ordered.map((record) => record.id),
      sightings: sightings.map((item) => ({ recordId: item.record.id, location: item.location })),
      locations,
      sessions: new Set(group.all.map((record) => record.session)).size,
      first: sightings[0]?.record.timestamp ?? null,
      last: sightings.at(-1)?.record.timestamp ?? null,
      context,
      contextLabels: [...group.cameras].sort(),
      window,
    });
    result.coverage.independent += sightings.length;
    result.coverage.locations += locations;
  }
  result.coverage.duplicates = result.coverage.eligible - result.coverage.independent;
  result.assessments.sort((a, b) => compareWindows(a.window, b.window) || a.id.localeCompare(b.id));
  return result;
}

export function assessmentView(
  assessment: CoTravelAssessment,
  trusted: boolean,
): 'candidates' | 'observed' | 'context' | 'trusted' {
  return trusted
    ? 'trusted'
    : assessment.context
      ? 'context'
      : assessment.window?.qualifies
        ? 'candidates'
        : 'observed';
}
