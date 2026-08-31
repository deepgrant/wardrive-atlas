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
export const TRUST_LOCK_NAME = TRUST_KEY;
export const TRUST_LOCK_TIMEOUT_MS = 5000;
export const TrustOperationSchema = z.strictObject({
  action: z.enum(['trust', 'untrust']),
  device: TrustedDeviceSchema,
});
export type TrustOperation = z.infer<typeof TrustOperationSchema>;
export const trustedIdentity = (entry: TrustedDevice): string => `${entry.type}:${entry.digest}`;

export interface TrustLock {
  /** Resolve after the exclusive callback completes; abort cancels acquisition. */
  run(signal: AbortSignal, operation: () => void): Promise<void>;
}
export interface TrustState {
  settings: TrustedSettings;
  saved: TrustedSettings;
  overrides: TrustOperation[];
  pending: boolean;
  warning: string | null;
}
export interface TrustControllerOptions {
  storage: RuleStorage;
  lock: TrustLock | null;
  subscribeRefresh?: (refresh: () => void) => () => void;
}
export type TrustMutationResult = 'saved' | 'tab-only' | 'rejected';

const READ_WARNING = 'Saved trusted devices could not be read or validated. No saved trust entries are active.';
const TAB_WARNING =
  'Tab-only trust changes apply only here. They are not saved or retried automatically; previously saved choices may return after reload.';
const emptySettings = (): TrustedSettings => ({ version: 1, devices: [] });

function readTrustedDevices(storage: RuleStorage): TrustedSettings {
  const text = storage.getItem(TRUST_KEY);
  if (text === null) return emptySettings();
  if (text.length > 1_000_000) throw new Error('Oversized settings');
  return TrustedSettingsSchema.parse(JSON.parse(text));
}

export async function identityDigest(record: Pick<WardriveRecord, 'bssid' | 'type'>): Promise<string | null> {
  const address = normalizeAddress(record.bssid);
  if (!address) return null;
  const bytes = new TextEncoder().encode(`wardrive-atlas:co-travel:v1|${record.type}|${address}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function loadTrustedDevices(storage: RuleStorage): { settings: TrustedSettings; warning: string | null } {
  try {
    return { settings: readTrustedDevices(storage), warning: null };
  } catch {
    return { settings: emptySettings(), warning: READ_WARNING };
  }
}

class TrustCapacityError extends Error {}

/** The only full-list writer. Call exclusively while holding TRUST_LOCK_NAME. */
function persistOperation(storage: RuleStorage, operation: TrustOperation): void {
  let settings: TrustedSettings;
  try {
    settings = readTrustedDevices(storage);
  } catch {
    throw new Error('Saved trust data could not be safely read or validated.');
  }
  const key = trustedIdentity(operation.device);
  const exists = settings.devices.some((entry) => trustedIdentity(entry) === key);
  if (operation.action === 'trust') {
    if (!exists) {
      if (settings.devices.length >= 10_000)
        throw new TrustCapacityError('The saved trusted list is full. Remove an entry before adding another.');
      settings.devices.push(operation.device);
    }
  } else settings.devices = settings.devices.filter((entry) => trustedIdentity(entry) !== key);
  // Even an idempotent operation checks write access before clearing a tab-only override.
  try {
    storage.setItem(TRUST_KEY, JSON.stringify(TrustedSettingsSchema.parse(settings)));
  } catch {
    throw new Error('Browser storage could not be updated.');
  }
}

export class TrustStateController {
  private saved = emptySettings();
  private readonly overrides = new Map<string, TrustOperation>();
  private readonly listeners = new Set<(state: TrustState) => void>();
  private readWarning: string | null = null;
  private operationWarning: string | null = null;
  private pending = false;
  private disposed = false;
  private acquisition: AbortController | null = null;
  private readonly unsubscribeRefresh: () => void;

  constructor(private readonly options: TrustControllerOptions) {
    this.refresh();
    this.unsubscribeRefresh = options.subscribeRefresh?.(() => this.refresh()) ?? (() => {});
  }

  getSnapshot(): TrustState {
    const devices = new Map(this.saved.devices.map((entry) => [trustedIdentity(entry), { ...entry }]));
    for (const [key, operation] of this.overrides) {
      if (operation.action === 'trust') devices.set(key, { ...operation.device });
      else devices.delete(key);
    }
    return {
      settings: { version: 1, devices: [...devices.values()] },
      saved: { version: 1, devices: this.saved.devices.map((entry) => ({ ...entry })) },
      overrides: [...this.overrides.values()].map((operation) => ({ ...operation, device: { ...operation.device } })),
      pending: this.pending,
      warning:
        [this.readWarning, this.operationWarning, this.overrides.size ? TAB_WARNING : null].filter(Boolean).join(' ') ||
        null,
    };
  }

  subscribe(listener: (state: TrustState) => void): () => void {
    if (this.disposed) return () => {};
    this.listeners.add(listener);
    listener(this.getSnapshot());
    return () => {
      this.listeners.delete(listener);
    };
  }

  refresh(): void {
    if (this.disposed) return;
    const loaded = loadTrustedDevices(this.options.storage);
    this.saved = loaded.settings;
    this.readWarning = loaded.warning;
    this.publish();
  }

  async mutate(input: unknown): Promise<TrustMutationResult> {
    if (this.disposed || this.pending) return 'rejected';
    const parsed = TrustOperationSchema.safeParse(input);
    if (!parsed.success) {
      this.operationWarning = 'That trust change is invalid. No changes were made.';
      this.publish();
      return 'rejected';
    }
    // Zod copies the explicit action and identity before any asynchronous work.
    const operation = parsed.data;
    const key = trustedIdentity(operation.device);
    const acquisition = new AbortController();
    this.acquisition = acquisition;
    this.pending = true;
    this.operationWarning = null;
    this.publish();
    let result: TrustMutationResult;
    try {
      await this.persist(operation, acquisition.signal);
      this.overrides.delete(key);
      result = 'saved';
    } catch (error) {
      if (this.disposed) return 'rejected';
      if (error instanceof TrustCapacityError) {
        this.operationWarning = error.message;
        result = 'rejected';
      } else {
        this.overrides.set(key, operation);
        this.operationWarning = error instanceof Error ? error.message : 'Trust could not be saved safely.';
        result = 'tab-only';
      }
    } finally {
      this.pending = false;
      this.acquisition = null;
    }
    // Neither event snapshots nor a completed write's snapshot are authoritative:
    // another tab may have serialized a newer operation before this continuation.
    this.refresh();
    return result;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.acquisition?.abort(new Error('Trust controller closed.'));
    this.unsubscribeRefresh();
    this.listeners.clear();
    this.overrides.clear();
  }

  private async persist(operation: TrustOperation, signal: AbortSignal): Promise<void> {
    signal.throwIfAborted();
    const lock = this.options.lock;
    if (!lock) throw new Error('This browser cannot coordinate safe trust saves.');
    let rejectAbort: (reason: unknown) => void = () => {};
    const aborted = new Promise<never>((_, reject) => {
      rejectAbort = reject;
    });
    const onAbort = (): void => rejectAbort(signal.reason);
    signal.addEventListener('abort', onAbort, { once: true });
    const timeout = setTimeout(() => {
      this.acquisition?.abort(new Error('The trust save lock was unavailable for five seconds.'));
    }, TRUST_LOCK_TIMEOUT_MS);
    try {
      await Promise.race([
        aborted,
        lock.run(signal, () => {
          // Guard against a late callback even if an adapter ignores cancellation.
          signal.throwIfAborted();
          clearTimeout(timeout);
          persistOperation(this.options.storage, operation);
        }),
      ]);
    } finally {
      clearTimeout(timeout);
      signal.removeEventListener('abort', onAbort);
    }
  }

  private publish(): void {
    for (const listener of this.listeners) listener(this.getSnapshot());
  }
}
