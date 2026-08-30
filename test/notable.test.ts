import { describe, expect, it } from 'vitest';
import { parseWardriveCsv, WardriveRecordSchema, type WardriveRecord } from '../src/csv';
import { BUILTIN_CATALOG, CatalogSchema } from '../src/notable-rules';
import morningCsv from './fixtures/notable-morning.csv?raw';
import eveningCsv from './fixtures/notable-evening.csv?raw';
import {
  analyzeCandidates,
  candidateFeatures,
  candidateKey,
  compileRules,
  emptyRuleSettings,
  evidenceLabel,
  loadRuleSettings,
  matchRecord,
  normalizeAddress,
  parseRuleSettings,
  PrefixSchema,
  RuleSettingsSchema,
  saveRuleSettings,
  SETTINGS_KEY,
  sortCandidates,
} from '../src/notable';

function record(changes: Partial<WardriveRecord> = {}): WardriveRecord {
  return WardriveRecordSchema.parse({
    id: 'row-1',
    session: 'synthetic.csv',
    bssid: 'B4:1E:52:00:00:01',
    ssid: 'Hidden network',
    authMode: 'Unknown',
    security: 'Other',
    firstSeen: '2026-08-29T10:00:00Z',
    timestamp: Date.UTC(2026, 7, 29, 10),
    channel: 6,
    band: '2.4 GHz',
    rssi: -60,
    latitude: 42.6,
    longitude: -71.4,
    altitude: null,
    accuracy: null,
    type: 'Wi-Fi',
    ...changes,
  });
}
const settings = emptyRuleSettings();
function matches(changes: Partial<WardriveRecord>, research = false): string[] {
  return matchRecord(record(changes), BUILTIN_CATALOG.rules, settings, research).map((rule) => rule.id);
}

describe('optional manufacturer evidence', () => {
  it('preserves hexadecimal MfgrId without dropping malformed or empty optional values', () => {
    const input =
      'MAC,SSID,CurrentLatitude,CurrentLongitude,MfgrId,Type\nB4:1E:52:00:00:01,"Penguin-SAMPLE, quoted",42,-71,0x09c8,BLE\n00:25:DF:00:00:02,example,42,-71,34d,BLE\n12:34:56:78:90:AB,other,42,-71,not-hex,BLE\n12:34:56:78:90:AC,other,42,-71,,BLE';
    const records = parseWardriveCsv(input);
    expect(records).toHaveLength(4);
    expect(records.map((item) => item.manufacturerId)).toEqual(['09C8', '034D', null, null]);
    expect(records[0]!.ssid).toBe('Penguin-SAMPLE, quoted');
  });
  it('accepts old CSV files and defaults absent manufacturer evidence to null', () => {
    expect(
      parseWardriveCsv('MAC,SSID,CurrentLatitude,CurrentLongitude\naa,example,42,-71')[0]!.manufacturerId,
    ).toBeNull();
  });
});

describe('published signature matching', () => {
  it('validates a unique, versioned, attributed built-in catalog', () => {
    expect(CatalogSchema.safeParse(BUILTIN_CATALOG).success).toBe(true);
    expect(BUILTIN_CATALOG.rules.every((rule) => rule.source?.startsWith('https://'))).toBe(true);
    expect(
      CatalogSchema.safeParse({ ...BUILTIN_CATALOG, rules: [BUILTIN_CATALOG.rules[0], BUILTIN_CATALOG.rules[0]] })
        .success,
    ).toBe(false);
  });
  it.each(['b4:1e:52:00:00:01', 'B4-1E-52-00-00-01', 'B41E.5200.0001', 'B41E52000001'])(
    'matches normalized Flock prefix %s without modifying the record',
    (address) => {
      const input = record({ bssid: address });
      expect(matchRecord(input, BUILTIN_CATALOG.rules, settings).map((rule) => rule.id)).toEqual(['flock-oui']);
      expect(input.bssid).toBe(address);
      expect(normalizeAddress(address)).toBe('B41E52000001');
    },
  );
  it.each(['', 'unknown', 'B4:1E:52', 'B4:1E:52:00:00:01:02', 'B4:1E-52:00:00:01', '000000000000', 'FFFFFFFFFFFF'])(
    'does not use invalid address %s for prefix evidence',
    (address) => {
      expect(normalizeAddress(address)).toBeNull();
      expect(matches({ bssid: address || 'Unknown' })).toEqual([]);
    },
  );
  it.each(['Penguin-123', 'flock-SAMPLE', 'pigvision', 'FS Ext Battery'])(
    'matches documented Bluetooth name %s',
    (ssid) => {
      expect(matches({ bssid: 'Unknown', type: 'BLE', ssid }).some((id) => id.startsWith('flock-name'))).toBe(true);
      expect(matches({ bssid: 'Unknown', type: 'Wi-Fi', ssid })).toEqual([]);
    },
  );
  it('does not match incidental Flock text or an empty prefix suffix', () => {
    expect(matches({ bssid: 'Unknown', type: 'BLE', ssid: 'My flock of birds' })).toEqual([]);
    expect(matches({ bssid: 'Unknown', type: 'BLE', ssid: 'Penguin-' })).toEqual([]);
  });
  it('uses Bluetooth manufacturer IDs separately from MAC prefixes', () => {
    expect(matches({ bssid: 'Unknown', type: 'BLE', manufacturerId: '09C8' })).toEqual(['flock-company']);
    expect(matches({ bssid: 'Unknown', type: 'BLE', manufacturerId: '034D' })).toEqual(['axon-company']);
    expect(matches({ bssid: 'Unknown', type: 'Wi-Fi', manufacturerId: '034D' })).toEqual([]);
    expect(matches({ bssid: 'Unknown', type: 'Wi-Fi', manufacturerId: '09C8' })).toEqual([]);
  });
  it('limits the built-in Axon prefix to Bluetooth', () => {
    expect(matches({ bssid: '00:25:DF:00:00:01', type: 'BLE' })).toEqual(['axon-oui']);
    expect(matches({ bssid: '00:25:DF:00:00:01', type: 'Wi-Fi' })).toEqual([]);
  });
  it.each(['Ray-Ban SAMPLE', 'My wayfarer', 'Oakley Meta'])(
    'matches Meta name %s but never a manufacturer ID alone',
    (ssid) => {
      expect(matches({ bssid: 'DA:00:00:00:00:01', type: 'BLE', ssid }).some((id) => id.startsWith('meta-name'))).toBe(
        true,
      );
      expect(matches({ bssid: 'DA:00:00:00:00:01', type: 'BLE', manufacturerId: '0D53' })).toEqual([]);
    },
  );
  it('retains multiple pieces of evidence without inflating candidate counts', () => {
    const result = analyzeCandidates(
      [record({ type: 'BLE', ssid: 'Penguin-SAMPLE', manufacturerId: '09C8' })],
      settings,
    );
    expect(result).toHaveLength(1);
    expect(result[0]!.evidence).toHaveLength(3);
    expect(result[0]!.categories).toEqual(['flock']);
    expect(result[0]!.evidence.map(evidenceLabel)).toEqual(['Manufacturer ID', 'Device name', 'Vendor prefix']);
  });
});

describe('research leads and address caveats', () => {
  it('requires opt-in for shared hardware prefixes and serial-only names', () => {
    expect(matches({ bssid: '70:C9:4E:00:00:01' })).toEqual([]);
    expect(matches({ bssid: '70:C9:4E:00:00:01' }, true)).toEqual(['flock-research-70C94E']);
    expect(matches({ bssid: 'Unknown', type: 'BLE', ssid: '0123456789' })).toEqual([]);
    expect(matches({ bssid: 'Unknown', type: 'BLE', ssid: '0123456789' }, true)).toEqual(['flock-serial']);
    expect(matches({ bssid: 'Unknown', type: 'BLE', ssid: '01234567890' }, true)).toEqual([]);
    expect(matches({ bssid: '70:C9:4E:00:00:01', type: 'BLE' }, true)).toEqual([]);
  });
  it.each(['F8A2D6', 'CCCCCC', '000CE7', '942A6F', 'F4E2C6', '6CCDD6'])(
    'excludes withdrawn prefix %s even with research enabled',
    (prefix) => {
      expect(matches({ bssid: `${prefix}000001` }, true)).toEqual([]);
    },
  );
  it('allows the explicitly published local prefix only as a weak research lead', () => {
    expect(matches({ bssid: '82:6B:F2:00:00:01' })).toEqual([]);
    expect(matches({ bssid: '82:6B:F2:00:00:01' }, true)).toEqual(['flock-research-826BF2']);
    expect(analyzeCandidates([record({ bssid: '82:6B:F2:00:00:01' })], settings, true)[0]!.weak).toBe(true);
  });
  it('applies Wi-Fi address-bit guards without pretending Bluetooth address type is known', () => {
    const base = BUILTIN_CATALOG.rules[0]!;
    const rule = { ...base, match: { kind: 'prefix' as const, value: 'DA0000', allowLocal: false } };
    expect(matchRecord(record({ bssid: 'DA:00:00:00:00:01' }), [rule], settings)).toHaveLength(0);
    expect(matchRecord(record({ bssid: 'DA:00:00:00:00:01', type: 'BLE' }), [rule], settings)).toHaveLength(1);
  });
});

describe('grouping, filtering and map projections', () => {
  it('imports multiple synthetic session files, excludes false positives, and groups the repeated address', () => {
    const rows = [...parseWardriveCsv(morningCsv, 'morning.csv'), ...parseWardriveCsv(eveningCsv, 'evening.csv')];
    expect(rows).toHaveLength(10);
    const defaults = analyzeCandidates(rows, settings);
    expect(defaults).toHaveLength(3);
    expect(candidateFeatures(defaults).features).toHaveLength(4);
    const flock = defaults.find((group) => group.categories.includes('flock'))!;
    expect(flock.records).toHaveLength(4);
    expect(flock.representatives.map((row) => row.rssi)).toEqual([-35, -40]);
    expect(analyzeCandidates(rows, settings, true)).toHaveLength(5);
  });
  it('groups by address and radio, retaining all filtered sightings and a strongest point per session', () => {
    const rows = [
      record({ id: 'a', rssi: -70 }),
      record({ id: 'b', bssid: 'b4-1e-52-00-00-01', rssi: -30, latitude: 42.7 }),
      record({ id: 'c', session: 'second.csv', rssi: -50 }),
      record({ id: 'd', type: 'BLE' }),
    ];
    const groups = analyzeCandidates(rows, settings);
    expect(groups).toHaveLength(2);
    const wifi = groups.find((group) => group.records[0]!.type === 'Wi-Fi')!;
    expect(wifi.records).toHaveLength(3);
    expect(wifi.representatives.map((item) => item.id)).toEqual(['b', 'c']);
    expect(wifi.strongest).toBe(-30);
    expect(candidateFeatures([wifi]).features.map((feature) => feature.geometry.coordinates)).toEqual([
      [-71.4, 42.7],
      [-71.4, 42.6],
    ]);
    const filtered = analyzeCandidates(
      rows.filter((row) => row.session === 'second.csv'),
      settings,
    );
    expect(filtered).toHaveLength(1);
    expect(filtered[0]!.representatives.map((row) => row.id)).toEqual(['c']);
    expect(analyzeCandidates([], settings)).toEqual([]);
  });
  it('uses earliest valid timestamp when signal is missing, then stable input order', () => {
    const rows = [
      record({ id: 'unknown', rssi: null, timestamp: null }),
      record({ id: 'late', rssi: null, timestamp: 200 }),
      record({ id: 'early', rssi: null, timestamp: 100 }),
      record({ id: 'tied', rssi: null, timestamp: 100 }),
    ];
    const group = analyzeCandidates(rows, settings)[0]!;
    expect(group.representatives[0]!.id).toBe('early');
    expect(group.firstSeen).toBe(100);
    expect(group.lastSeen).toBe(200);
    expect(group.strongest).toBeNull();
  });
  it('includes same-address sightings without the original name/manufacturer evidence', () => {
    const rows = [
      record({ id: 'a', bssid: 'DA:00:00:00:00:01', type: 'BLE', ssid: 'Ray-Ban SAMPLE' }),
      record({ id: 'b', bssid: 'DA:00:00:00:00:01', type: 'BLE', ssid: 'Hidden network', rssi: -20 }),
    ];
    const groups = analyzeCandidates(rows, settings);
    expect(groups[0]!.records).toHaveLength(2);
    expect(groups[0]!.representatives[0]!.id).toBe('b');
    expect(analyzeCandidates([rows[1]!], settings)).toEqual([]);
  });
  it('does not combine rotating or missing addresses just because their names are equal', () => {
    const rows = [
      record({ id: 'a', bssid: 'DA:00:00:00:00:01', type: 'BLE', ssid: 'Ray-Ban SAMPLE' }),
      record({ id: 'b', bssid: 'DA:00:00:00:00:02', type: 'BLE', ssid: 'Ray-Ban SAMPLE' }),
      record({ id: 'c', bssid: 'Unknown', type: 'BLE', ssid: 'Ray-Ban SAMPLE' }),
      record({ id: 'd', bssid: 'Unknown', type: 'BLE', ssid: 'Ray-Ban SAMPLE' }),
    ];
    expect(analyzeCandidates(rows, settings)).toHaveLength(4);
  });
  it('sorts by evidence before signal, with separate signal and recent sorts', () => {
    const rows = [
      record({ id: 'oui', rssi: -30, timestamp: 100 }),
      record({ id: 'mfr', bssid: 'DA:00:00:00:00:01', type: 'BLE', manufacturerId: '034D', rssi: -70, timestamp: 200 }),
      record({ id: 'lead', bssid: '70:C9:4E:00:00:01', rssi: -20, timestamp: 300 }),
    ];
    const groups = analyzeCandidates(rows, settings, true);
    expect(groups.map((group) => group.records[0]!.id)).toEqual(['mfr', 'oui', 'lead']);
    expect(sortCandidates(groups, 'signal').map((group) => group.records[0]!.id)).toEqual(['lead', 'oui', 'mfr']);
    expect(sortCandidates(groups, 'recent').map((group) => group.records[0]!.id)).toEqual(['lead', 'mfr', 'oui']);
  });
  it('uses opaque identifiers and no names, addresses, or filenames in map properties', () => {
    const feature = candidateFeatures(
      analyzeCandidates([record({ ssid: 'sensitive name', session: 'private file.csv' })], settings),
    ).features[0]!;
    expect(feature.properties).toEqual({ candidateId: 'candidate-0', icon: 'notable-flock-solid' });
    expect(JSON.stringify(feature)).not.toMatch(/B4:1E|sensitive|private file/);
  });
  it('dismisses and restores a candidate without changing imported rows', () => {
    const rows = [record()];
    const dismissed = new Set([candidateKey(rows[0]!)]);
    expect(analyzeCandidates(rows, settings, false, dismissed)).toEqual([]);
    dismissed.clear();
    expect(analyzeCandidates(rows, settings, false, dismissed)).toHaveLength(1);
    expect(rows).toHaveLength(1);
  });
});

describe('custom, ignored and persisted rules', () => {
  it('validates and canonicalizes exactly three prefix bytes', () => {
    expect(PrefixSchema.parse(' b4:1e:52 ')).toBe('B41E52');
    expect(PrefixSchema.parse('b4-1e-52')).toBe('B41E52');
    for (const invalid of ['B4', 'B4:1E:52:00', 'B4:1E-52', 'anything', 'B4.1E.52'])
      expect(PrefixSchema.safeParse(invalid).success).toBe(false);
  });
  it('marks custom rules and gives ignored prefixes protocol-specific precedence', () => {
    const custom = RuleSettingsSchema.parse({
      version: 1,
      custom: [{ prefix: 'B41E52', category: 'meta', protocol: 'Both' }],
      ignored: [{ prefix: 'B41E52', protocol: 'Wi-Fi' }],
    });
    const rows = [record(), record({ id: 'bt', type: 'BLE' })];
    const result = analyzeCandidates(rows, custom);
    expect(result).toHaveLength(1);
    expect(result[0]!.categories).toEqual(['meta', 'flock']);
    expect(result[0]!.evidence.some((rule) => evidenceLabel(rule) === 'User-defined prefix')).toBe(true);
    custom.ignored[0]!.protocol = 'Both';
    expect(analyzeCandidates(rows, custom)).toEqual([]);
    expect(rows).toHaveLength(2);
  });
  it('lets custom rules explicitly target local prefixes but rejects Wi-Fi multicast', () => {
    const custom = RuleSettingsSchema.parse({
      version: 1,
      custom: [
        { prefix: 'DA0000', category: 'axon', protocol: 'Wi-Fi' },
        { prefix: 'FF0000', category: 'flock', protocol: 'Wi-Fi' },
      ],
      ignored: [],
    });
    expect(matchRecord(record({ bssid: 'DA:00:00:00:00:01' }), compileRules(custom), custom)).toHaveLength(1);
    expect(matchRecord(record({ bssid: 'FF:00:00:00:00:01' }), compileRules(custom), custom)).toHaveLength(0);
  });
  it('round-trips only versioned custom/ignored settings', () => {
    const memory = new Map<string, string>();
    const storage = {
      getItem: (key: string) => memory.get(key) ?? null,
      setItem: (key: string, value: string) => {
        memory.set(key, value);
      },
    };
    expect(loadRuleSettings(storage)).toEqual({ settings: emptyRuleSettings(), warning: null });
    const custom = RuleSettingsSchema.parse({
      version: 1,
      custom: [{ prefix: 'b4:1e:52', category: 'flock', protocol: 'Both' }],
      ignored: [],
    });
    expect(saveRuleSettings(storage, custom)).toBe(true);
    expect(loadRuleSettings(storage).settings).toEqual(custom);
    expect([...memory.keys()]).toEqual([SETTINGS_KEY]);
    expect(Object.keys(JSON.parse(memory.get(SETTINGS_KEY)!))).toEqual(['version', 'custom', 'ignored']);
  });
  it.each([
    'not json',
    '{"version":2,"custom":[],"ignored":[]}',
    '{"version":1,"custom":[],"ignored":[],"captures":[]}',
  ])('falls back visibly for invalid storage: %s', (text) => {
    const result = loadRuleSettings({ getItem: () => text, setItem: () => {} });
    expect(result.settings).toEqual(emptyRuleSettings());
    expect(result.warning).toBeTruthy();
    expect(() => parseRuleSettings(text)).toThrow();
  });
  it('handles unavailable storage and limits untrusted file sizes', () => {
    const storage = {
      getItem: (): string => {
        throw new Error('Blocked');
      },
      setItem: () => {
        throw new Error('Full');
      },
    };
    expect(loadRuleSettings(storage).warning).toBeTruthy();
    expect(saveRuleSettings(storage, emptyRuleSettings())).toBe(false);
    expect(() => parseRuleSettings(' '.repeat(128_001))).toThrow(/128 KB/);
  });
});
