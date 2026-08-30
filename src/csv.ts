import { z } from 'zod';

const HEADER_HINTS = new Set([
  'mac',
  'bssid',
  'ssid',
  'authmode',
  'firstseen',
  'currentlatitude',
  'currentlongitude',
  'type',
]);

export const SignalTypeSchema = z.enum(['Wi-Fi', 'BLE']);
export const BandSchema = z.enum(['2.4 GHz', '5 GHz', '6 GHz', 'Bluetooth', 'Unknown']);
export const SecuritySchema = z.enum(['Open', 'WPA3', 'WPA2', 'WPA', 'WEP', 'Other']);

export const WardriveRecordSchema = z.object({
  id: z.string().min(1),
  session: z.string().min(1),
  bssid: z.string().min(1),
  ssid: z.string().min(1),
  authMode: z.string().min(1),
  security: SecuritySchema,
  firstSeen: z.string(),
  timestamp: z.number().finite().nullable(),
  channel: z.number().int().nullable(),
  band: BandSchema,
  rssi: z.number().finite().nullable(),
  latitude: z.number().finite().min(-90).max(90),
  longitude: z.number().finite().min(-180).max(180),
  altitude: z.number().finite().nullable(),
  accuracy: z.number().finite().nonnegative().nullable(),
  manufacturerId: z
    .string()
    .regex(/^[0-9A-F]{4}$/)
    .nullable()
    .default(null),
  type: SignalTypeSchema,
});

export type Band = z.infer<typeof BandSchema>;
export type Security = z.infer<typeof SecuritySchema>;
export type WardriveRecord = z.infer<typeof WardriveRecordSchema>;

const SourceRowSchema = z.record(z.string(), z.string());

// Biscuit's MfgrId is a hexadecimal Bluetooth company identifier, not an OUI.
// Preserve valid IDs without guessing decimal encodings or byte order.
export function normalizeManufacturerId(value: string | undefined): string | null {
  const hex = (value ?? '').trim().replace(/^0x/i, '');
  return /^[0-9a-f]{1,4}$/i.test(hex) ? hex.toUpperCase().padStart(4, '0') : null;
}

export function parseCsvRows(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  const input = String(text ?? '').replace(/^\uFEFF/, '');

  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];

    if (quoted) {
      if (character === '"' && input[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        field += character;
      }
    } else if (character === '"') {
      quoted = true;
    } else if (character === ',') {
      row.push(field);
      field = '';
    } else if (character === '\n') {
      row.push(field.replace(/\r$/, ''));
      if (row.some((value) => value.length > 0)) rows.push(row);
      row = [];
      field = '';
    } else {
      field += character;
    }
  }

  if (field.length || row.length) {
    row.push(field.replace(/\r$/, ''));
    if (row.some((value) => value.length > 0)) rows.push(row);
  }

  return rows;
}

function normalizedHeader(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

export function findHeaderRow(rows: readonly string[][]): number {
  const candidates = rows.slice(0, 8);
  let bestIndex = -1;
  let bestScore = 0;

  candidates.forEach((row, index) => {
    const score = row.reduce((total, value) => total + (HEADER_HINTS.has(normalizedHeader(value)) ? 1 : 0), 0);
    if (score > bestScore) {
      bestIndex = index;
      bestScore = score;
    }
  });

  return bestScore >= 2 ? bestIndex : -1;
}

function readNumber(value: string | undefined): number | null {
  const number = Number.parseFloat(value ?? '');
  return Number.isFinite(number) ? number : null;
}

function readChannel(value: string | undefined): number | null {
  const number = Number.parseInt(value ?? '', 10);
  return Number.isFinite(number) ? number : null;
}

export function getBand(channel: number | null, type: string): Band {
  const normalizedType = type.toLowerCase();
  if (normalizedType.includes('ble') || normalizedType.includes('bluetooth')) return 'Bluetooth';
  if (channel === null) return 'Unknown';
  if (channel >= 1 && channel <= 14) return '2.4 GHz';
  if (channel >= 32 && channel <= 177) return '5 GHz';
  if (channel > 177) return '6 GHz';
  return 'Unknown';
}

export function getSecurity(authMode: string | undefined): Security {
  const mode = (authMode ?? '').toUpperCase();
  if (!mode || mode.includes('OPEN') || mode.includes('NONE')) return 'Open';
  if (mode.includes('WPA3')) return 'WPA3';
  if (mode.includes('WPA2')) return 'WPA2';
  if (mode.includes('WPA')) return 'WPA';
  if (mode.includes('WEP')) return 'WEP';
  return 'Other';
}

export function parseWardriveCsv(text: string, sessionName = 'Imported session'): WardriveRecord[] {
  const rows = parseCsvRows(text);
  const headerIndex = findHeaderRow(rows);
  if (headerIndex < 0) {
    throw new Error('No supported CSV header was found. Check that this is a Biscuit or WiGLE-format export.');
  }

  const headerRow = rows[headerIndex];
  if (!headerRow) throw new Error('The CSV header is empty.');
  const headers = headerRow.map(normalizedHeader);
  const records: WardriveRecord[] = [];

  for (const row of rows.slice(headerIndex + 1)) {
    const rawSource = Object.fromEntries(headers.map((header, index) => [header, row[index]?.trim() ?? '']));
    const sourceResult = SourceRowSchema.safeParse(rawSource);
    if (!sourceResult.success) continue;
    const source = sourceResult.data;
    const latitude = readNumber(source['currentlatitude'] ?? source['latitude']);
    const longitude = readNumber(source['currentlongitude'] ?? source['longitude']);
    if (latitude === null || longitude === null) continue;

    const type = source['type'] || 'WIFI';
    const channel = readChannel(source['channel']);
    const timestamp = source['firstseen'] || source['timestamp'] || '';
    const parsedTime = Date.parse(timestamp);
    const candidate = {
      id: `${sessionName}:${records.length}`,
      session: sessionName,
      bssid: source['mac'] || source['bssid'] || 'Unknown device',
      ssid: source['ssid'] || 'Hidden network',
      authMode: source['authmode'] || 'Unknown',
      security: getSecurity(source['authmode']),
      firstSeen: timestamp,
      timestamp: Number.isFinite(parsedTime) ? parsedTime : null,
      channel,
      band: getBand(channel, type),
      rssi: readNumber(source['rssi']),
      latitude,
      longitude,
      altitude: readNumber(source['altitudemeters'] ?? source['altitude']),
      accuracy: readNumber(source['accuracymeters'] ?? source['accuracy']),
      manufacturerId: normalizeManufacturerId(source['mfgrid']),
      type: type.toUpperCase().includes('BLE') || type.toUpperCase().includes('BLUETOOTH') ? 'BLE' : 'Wi-Fi',
    };
    const recordResult = WardriveRecordSchema.safeParse(candidate);
    if (recordResult.success) records.push(recordResult.data);
  }

  if (!records.length) {
    throw new Error('The file has a header, but no rows with valid latitude and longitude values.');
  }

  return records;
}
