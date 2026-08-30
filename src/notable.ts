import { z } from 'zod';
import type { FeatureCollection, Point } from 'geojson';
import type { WardriveRecord } from './csv';
import { BUILTIN_CATALOG, CategorySchema, type Category, type DetectionRule } from './notable-rules';

export function normalizeAddress(value: string): string | null {
  const text = value.trim();
  if (
    !/^(?:[\da-f]{12}|(?:[\da-f]{2}:){5}[\da-f]{2}|(?:[\da-f]{2}-){5}[\da-f]{2}|(?:[\da-f]{4}\.){2}[\da-f]{4})$/i.test(
      text,
    )
  )
    return null;
  const normalized = text.replace(/[:.\-]/g, '').toUpperCase();
  return /^(0{12}|F{12})$/.test(normalized) ? null : normalized;
}

export const PrefixSchema = z
  .string()
  .trim()
  .refine(
    (value) => /^(?:[\da-f]{6}|(?:[\da-f]{2}:){2}[\da-f]{2}|(?:[\da-f]{2}-){2}[\da-f]{2})$/i.test(value),
    'Enter exactly three hexadecimal bytes, such as B4:1E:52.',
  )
  .transform((value) => value.replace(/[:-]/g, '').toUpperCase());
export const ProtocolSchema = z.enum(['Both', 'Wi-Fi', 'BLE']);
export const CustomPrefixSchema = z.strictObject({
  prefix: PrefixSchema,
  category: CategorySchema,
  protocol: ProtocolSchema,
});
export const IgnoredPrefixSchema = z.strictObject({ prefix: PrefixSchema, protocol: ProtocolSchema });
export const RuleSettingsSchema = z.strictObject({
  version: z.literal(1),
  custom: z.array(CustomPrefixSchema).max(500),
  ignored: z.array(IgnoredPrefixSchema).max(500),
});
export type RuleSettings = z.infer<typeof RuleSettingsSchema>;
export const SETTINGS_KEY = 'wardrive-atlas.notable-rules.v1';
export function emptyRuleSettings(): RuleSettings {
  return { version: 1, custom: [], ignored: [] };
}

export interface RuleStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export function parseRuleSettings(text: string): RuleSettings {
  if (text.length > 128_000) throw new Error('Rule files must be smaller than 128 KB.');
  return RuleSettingsSchema.parse(JSON.parse(text));
}

export function loadRuleSettings(storage: RuleStorage): { settings: RuleSettings; warning: string | null } {
  try {
    const text = storage.getItem(SETTINGS_KEY);
    return { settings: text === null ? emptyRuleSettings() : parseRuleSettings(text), warning: null };
  } catch {
    return {
      settings: emptyRuleSettings(),
      warning: 'Saved rules could not be read. Built-in rules are active; add or import your rules again.',
    };
  }
}

export function saveRuleSettings(storage: RuleStorage, settings: RuleSettings): boolean {
  try {
    storage.setItem(SETTINGS_KEY, JSON.stringify(RuleSettingsSchema.parse(settings)));
    return true;
  } catch {
    return false;
  }
}

export function candidateKey(record: WardriveRecord): string {
  // Invalid/missing addresses must not merge unrelated name-only observations.
  return `${record.type}:${normalizeAddress(record.bssid) ?? `row:${record.id}`}`;
}

export function compileRules(settings: RuleSettings): DetectionRule[] {
  return [
    ...BUILTIN_CATALOG.rules,
    ...settings.custom.map((rule, index): DetectionRule => ({
      id: `custom-${index}`,
      category: rule.category,
      protocols: rule.protocol === 'Both' ? ['Wi-Fi', 'BLE'] : [rule.protocol],
      match: { kind: 'prefix', value: rule.prefix, allowLocal: true },
      research: false,
      custom: true,
      explanation:
        'Matched a prefix you added. This is user-defined evidence, not an independently verified hardware classification.',
      source: null,
      sourceLabel: 'Your custom rule',
    })),
  ];
}

export function matchRecord(
  record: WardriveRecord,
  rules: readonly DetectionRule[],
  settings: RuleSettings,
  research = false,
): DetectionRule[] {
  const address = normalizeAddress(record.bssid);
  if (
    address &&
    settings.ignored.some(
      (rule) => (rule.protocol === 'Both' || rule.protocol === record.type) && address.startsWith(rule.prefix),
    )
  )
    return [];
  return rules.filter((rule) => {
    if ((!research && rule.research) || !rule.protocols.includes(record.type)) return false;
    const match = rule.match;
    switch (match.kind) {
      case 'prefix': {
        if (!address || !address.startsWith(match.value)) return false;
        // Wi-Fi I/G and U/L bits do not describe Bluetooth's public/random address type.
        if (record.type === 'Wi-Fi') {
          const firstByte = Number.parseInt(address.slice(0, 2), 16);
          if (firstByte & 1) return false;
          if (firstByte & 2 && !match.allowLocal) return false;
        }
        return true;
      }
      case 'manufacturer':
        return record.manufacturerId === match.value;
      case 'serial':
        return /^\d{10}$/.test(record.ssid.trim());
      case 'name': {
        const name = record.ssid.trim().toLowerCase();
        const value = match.value.toLowerCase();
        return match.mode === 'starts'
          ? name.startsWith(value) && name.length > value.length
          : match.mode === 'exact'
            ? name === value
            : name.includes(value);
      }
    }
  });
}

export function evidenceRank(rule: DetectionRule): number {
  return rule.research ? 2 : rule.match.kind === 'prefix' ? 1 : 0;
}
export function evidenceLabel(rule: DetectionRule): string {
  if (rule.research) return 'Research lead';
  if (rule.custom) return 'User-defined prefix';
  return rule.match.kind === 'prefix'
    ? 'Vendor prefix'
    : rule.match.kind === 'manufacturer'
      ? 'Manufacturer ID'
      : 'Device name';
}

export interface Candidate {
  id: string;
  key: string;
  records: WardriveRecord[];
  representatives: WardriveRecord[];
  evidence: DetectionRule[];
  categories: Category[];
  strongest: number | null;
  firstSeen: number | null;
  lastSeen: number | null;
  weak: boolean;
}
export type CandidateSort = 'evidence' | 'signal' | 'recent';

function observationOrder(a: WardriveRecord, b: WardriveRecord): number {
  return (b.rssi ?? -Infinity) - (a.rssi ?? -Infinity) || (a.timestamp ?? Infinity) - (b.timestamp ?? Infinity);
}

export function analyzeCandidates(
  records: readonly WardriveRecord[],
  settings: RuleSettings,
  research = false,
  dismissed: ReadonlySet<string> = new Set(),
): Candidate[] {
  const rules = compileRules(settings);
  const groups = new Map<string, { records: WardriveRecord[]; evidence: Map<string, DetectionRule> }>();
  for (const record of records) {
    const key = candidateKey(record);
    if (dismissed.has(key)) continue;
    let group = groups.get(key);
    if (!group) {
      group = { records: [], evidence: new Map() };
      groups.set(key, group);
    }
    group.records.push(record);
    for (const match of matchRecord(record, rules, settings, research)) group.evidence.set(match.id, match);
  }
  const candidates: Candidate[] = [];
  for (const [key, group] of groups) {
    if (!group.evidence.size) continue;
    const representatives = new Map<string, WardriveRecord>();
    let firstSeen: number | null = null;
    let lastSeen: number | null = null;
    let strongest: number | null = null;
    for (const record of group.records) {
      const existing = representatives.get(record.session);
      if (!existing || observationOrder(record, existing) < 0) representatives.set(record.session, record);
      if (record.timestamp !== null) {
        firstSeen = Math.min(firstSeen ?? Infinity, record.timestamp);
        lastSeen = Math.max(lastSeen ?? -Infinity, record.timestamp);
      }
      if (record.rssi !== null) strongest = Math.max(strongest ?? -Infinity, record.rssi);
    }
    const evidence = [...group.evidence.values()].sort(
      (a, b) => evidenceRank(a) - evidenceRank(b) || a.id.localeCompare(b.id),
    );
    candidates.push({
      id: `candidate-${candidates.length}`,
      key,
      records: group.records,
      representatives: [...representatives.values()],
      evidence,
      categories: [...new Set(evidence.map((rule) => rule.category))],
      strongest,
      firstSeen,
      lastSeen,
      weak: evidence.every((rule) => rule.research),
    });
  }
  return sortCandidates(candidates, 'evidence');
}

export function sortCandidates(candidates: readonly Candidate[], sort: CandidateSort): Candidate[] {
  return [...candidates].sort((a, b) => {
    if (sort === 'recent') return (b.lastSeen ?? -Infinity) - (a.lastSeen ?? -Infinity) || a.id.localeCompare(b.id);
    const evidence = sort === 'evidence' ? evidenceRank(a.evidence[0]!) - evidenceRank(b.evidence[0]!) : 0;
    return evidence || (b.strongest ?? -Infinity) - (a.strongest ?? -Infinity) || a.id.localeCompare(b.id);
  });
}

// Only opaque candidate IDs and display classes enter the map worker.
export function candidateFeatures(candidates: readonly Candidate[]): FeatureCollection<Point> {
  return {
    type: 'FeatureCollection',
    features: candidates.flatMap((candidate) =>
      candidate.representatives.map((record) => ({
        type: 'Feature' as const,
        properties: {
          candidateId: candidate.id,
          icon: `notable-${candidate.categories.length > 1 ? 'multiple' : candidate.categories[0]}-${candidate.weak ? 'weak' : 'solid'}`,
        },
        geometry: { type: 'Point' as const, coordinates: [record.longitude, record.latitude] },
      })),
    ),
  };
}
