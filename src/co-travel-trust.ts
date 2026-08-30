import { z } from 'zod';
import { SignalTypeSchema, type WardriveRecord } from './csv';
import { normalizeAddress, type RuleStorage } from './notable';

export const TrustedDeviceSchema = z.strictObject({
  digest: z.string().regex(/^[a-f0-9]{64}$/),
  type: SignalTypeSchema,
});
export const TrustedSettingsSchema = z.strictObject({
  version: z.literal(1),
  devices: z
    .array(TrustedDeviceSchema)
    .max(10_000)
    .refine(
      (entries) => new Set(entries.map((entry) => `${entry.type}:${entry.digest}`)).size === entries.length,
      'Duplicate trusted entries',
    ),
});
export type TrustedDevice = z.infer<typeof TrustedDeviceSchema>;
export type TrustedSettings = z.infer<typeof TrustedSettingsSchema>;
export const TRUST_KEY = 'wardrive-atlas.co-travel-trust.v1';

export async function identityDigest(record: Pick<WardriveRecord, 'bssid' | 'type'>): Promise<string | null> {
  const address = normalizeAddress(record.bssid);
  if (!address) return null;
  const bytes = new TextEncoder().encode(`wardrive-atlas:co-travel:v1|${record.type}|${address}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function loadTrustedDevices(storage: RuleStorage): { settings: TrustedSettings; warning: string | null } {
  try {
    const text = storage.getItem(TRUST_KEY);
    if (text === null) return { settings: { version: 1, devices: [] }, warning: null };
    if (text.length > 1_000_000) throw new Error('Oversized settings');
    return { settings: TrustedSettingsSchema.parse(JSON.parse(text)), warning: null };
  } catch {
    return {
      settings: { version: 1, devices: [] },
      warning: 'Trusted devices could not be read. No addresses are being treated as trusted.',
    };
  }
}

export function saveTrustedDevices(storage: RuleStorage, settings: TrustedSettings): boolean {
  try {
    storage.setItem(TRUST_KEY, JSON.stringify(TrustedSettingsSchema.parse(settings)));
    return true;
  } catch {
    return false;
  }
}
