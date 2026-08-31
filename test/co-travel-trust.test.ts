import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  TRUST_KEY,
  TRUST_LOCK_NAME,
  TRUST_LOCK_TIMEOUT_MS,
  TrustOperationSchema,
  TrustStateController,
  loadTrustedDevices,
  type TrustedDevice,
  type TrustLock,
} from '../src/co-travel-trust';
import { createBrowserTrustController } from '../src/co-travel-trust-browser';

const device = (id: number): TrustedDevice => ({ digest: id.toString(16).padStart(64, '0'), type: 'BLE' });
const A = device(1),
  B = device(2),
  C = device(3);
const trust = (entry: TrustedDevice) => ({ action: 'trust' as const, device: entry });
const untrust = (entry: TrustedDevice) => ({ action: 'untrust' as const, device: entry });
const serialized = (devices: TrustedDevice[]) => JSON.stringify({ version: 1, devices });

class MemoryStorage {
  data = new Map<string, string>();
  getItem = vi.fn((key: string): string | null => this.data.get(key) ?? null);
  setItem = vi.fn((key: string, value: string): void => {
    this.data.set(key, value);
  });
  seed(entries: TrustedDevice[]): void {
    this.data.set(TRUST_KEY, serialized(entries));
  }
  entries(): TrustedDevice[] {
    return loadTrustedDevices(this).settings.devices;
  }
}

class SerialLock implements TrustLock {
  private tail: Promise<void> = Promise.resolve();
  run(signal: AbortSignal, operation: () => void): Promise<void> {
    const next = this.tail.then(() => {
      signal.throwIfAborted();
      operation();
    });
    this.tail = next.catch(() => {});
    return next;
  }
}

function tabs(entries: TrustedDevice[] = []) {
  const storage = new MemoryStorage();
  storage.seed(entries);
  const lock = new SerialLock();
  const create = () => new TrustStateController({ storage, lock });
  return { storage, lock, create, first: create(), second: create() };
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('serialized one-address trust operations', () => {
  it('does not resurrect A when a stale tab trusts unrelated B, including after reload', async () => {
    const { storage, first, second, create } = tabs([A]);
    expect(first.getSnapshot().settings.devices).toEqual([A]);
    expect(second.getSnapshot().settings.devices).toEqual([A]);
    expect(await first.mutate(untrust(A))).toBe('saved');
    expect(await second.mutate(trust(B))).toBe('saved');
    expect(storage.entries()).toEqual([B]);
    expect(second.getSnapshot().settings.devices).toEqual([B]);
    expect(create().getSnapshot().settings.devices).toEqual([B]);
  });

  it('merges simultaneous additions from separate tabs', async () => {
    const { storage, first, second } = tabs();
    expect(await Promise.all([first.mutate(trust(A)), second.mutate(trust(B))])).toEqual(['saved', 'saved']);
    expect(storage.entries()).toEqual([A, B]);
  });

  it('preserves mixed additions and removals with stale local lists', async () => {
    const { storage, first, second, create } = tabs([A, B]);
    await Promise.all([first.mutate(untrust(A)), second.mutate(trust(C)), create().mutate(untrust(B))]);
    expect(storage.entries()).toEqual([C]);
  });

  it.each(['trust', 'untrust'] as const)('makes duplicate %s operations idempotent', async (action) => {
    const { storage, first, second } = tabs([A]);
    expect(await Promise.all([first.mutate({ action, device: A }), second.mutate({ action, device: A })])).toEqual([
      'saved',
      'saved',
    ]);
    expect(storage.entries()).toEqual(action === 'trust' ? [A] : []);
  });

  it.each([true, false])(
    'honors the last serialized explicit action for the same address: trust last = %s',
    async (trustLast) => {
      const { storage, first, second } = tabs();
      await Promise.all([
        first.mutate(trustLast ? untrust(A) : trust(A)),
        second.mutate(trustLast ? trust(A) : untrust(A)),
      ]);
      expect(storage.entries()).toEqual(trustLast ? [A] : []);
    },
  );

  it('keeps identical digests in different radios separate', async () => {
    const wifi: TrustedDevice = { ...A, type: 'Wi-Fi' };
    const { storage, first, second } = tabs([A, wifi]);
    await first.mutate(untrust(A));
    await second.mutate(trust(B));
    expect(storage.entries()).toEqual([wifi, B]);
  });

  it('enforces the 10,000-entry limit against the locked latest list under contention', async () => {
    const { storage, first, second } = tabs(Array.from({ length: 9999 }, (_, index) => device(index)));
    expect(await Promise.all([first.mutate(trust(device(10_000))), second.mutate(trust(device(10_001)))])).toEqual([
      'saved',
      'rejected',
    ]);
    expect(storage.entries()).toHaveLength(10_000);
    expect(second.getSnapshot()).toMatchObject({ overrides: [], warning: expect.stringContaining('full') });
    expect(await second.mutate(trust(device(10_000)))).toBe('saved');
    expect(await second.mutate(untrust(device(10_001)))).toBe('saved');
    expect(storage.entries()).toHaveLength(10_000);
  });

  it('allows a queued addition after a removal frees a slot', async () => {
    const { storage, first, second } = tabs(Array.from({ length: 10_000 }, (_, index) => device(index)));
    expect(await Promise.all([first.mutate(untrust(A)), second.mutate(trust(device(10_000)))])).toEqual([
      'saved',
      'saved',
    ]);
    expect(storage.entries()).toHaveLength(10_000);
    expect(storage.entries()).not.toContainEqual(A);
  });

  it.each([
    { action: 'toggle', device: A },
    { action: 'trust', device: { ...A, digest: 'short' } },
    { action: 'trust', device: { ...A, type: 'BT' } },
    { action: 'trust', device: { ...A, ssid: 'private' } },
    { action: 'trust', device: A, devices: [B] },
  ])('rejects malformed operations without persistence or local overrides: %j', async (input) => {
    const { storage, first } = tabs();
    expect(TrustOperationSchema.safeParse(input).success).toBe(false);
    expect(await first.mutate(input)).toBe('rejected');
    expect(storage.setItem).not.toHaveBeenCalled();
    expect(first.getSnapshot()).toMatchObject({ overrides: [], warning: expect.any(String) });
  });

  it('captures the target and explicit action before waiting, and blocks another operation in that tab', async () => {
    const { storage, first } = tabs();
    const operation = trust({ ...A });
    const pending = first.mutate(operation);
    expect(first.getSnapshot().pending).toBe(true);
    operation.device.digest = B.digest;
    expect(await first.mutate(untrust(A))).toBe('rejected');
    expect(await pending).toBe('saved');
    expect(storage.entries()).toEqual([A]);
    expect(first.getSnapshot().pending).toBe(false);
  });

  it('refreshes the writer directly and rereads after completion instead of publishing a stale commit snapshot', async () => {
    const storage = new MemoryStorage();
    // Another serialized writer removes A after this callback, before its continuation.
    const lock: TrustLock = {
      run: async (_, operation) => {
        operation();
        storage.seed([B]);
      },
    };
    const controller = new TrustStateController({ storage, lock });
    const changes = vi.fn();
    controller.subscribe(changes);
    await controller.mutate(trust(A));
    expect(controller.getSnapshot().settings.devices).toEqual([B]);
    expect(changes.mock.calls.at(-1)?.[0]).toMatchObject({ settings: { devices: [B] }, pending: false });
  });
});

describe('safe tab-only fallback', () => {
  it('never writes without a lock, even if storage is writable', async () => {
    const storage = new MemoryStorage();
    storage.seed([A]);
    const controller = new TrustStateController({ storage, lock: null });
    expect(await controller.mutate(trust(B))).toBe('tab-only');
    expect(storage.setItem).not.toHaveBeenCalled();
    expect(controller.getSnapshot()).toMatchObject({
      saved: { devices: [A] },
      settings: { devices: [A, B] },
      overrides: [trust(B)],
      warning: expect.stringContaining('Tab-only'),
    });
  });

  it('times out acquisition at five seconds and prevents a late callback from writing', async () => {
    vi.useFakeTimers();
    const storage = new MemoryStorage();
    let callback: (() => void) | undefined;
    let signal: AbortSignal | undefined;
    const lock: TrustLock = {
      run: (input, operation) => {
        signal = input;
        callback = operation;
        return new Promise(() => {});
      },
    };
    const controller = new TrustStateController({ storage, lock });
    const pending = controller.mutate(trust(A));
    await vi.advanceTimersByTimeAsync(TRUST_LOCK_TIMEOUT_MS - 1);
    expect(controller.getSnapshot()).toMatchObject({ pending: true, overrides: [] });
    await vi.advanceTimersByTimeAsync(1);
    expect(await pending).toBe('tab-only');
    expect(signal?.aborted).toBe(true);
    expect(controller.getSnapshot()).toMatchObject({
      pending: false,
      overrides: [trust(A)],
      warning: expect.stringContaining('five seconds'),
    });
    expect(callback).toThrow();
    expect(storage.setItem).not.toHaveBeenCalled();
  });

  it('stops the acquisition timer once the lock has been granted', async () => {
    vi.useFakeTimers();
    const { first } = tabs();
    expect(await first.mutate(trust(A))).toBe('saved');
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(TRUST_LOCK_TIMEOUT_MS);
    expect(first.getSnapshot()).toMatchObject({ pending: false, overrides: [], warning: null });
  });

  it.each(['not json', '{"version":2,"devices":[]}', serialized([A, A]), 'x'.repeat(1_000_001)])(
    'does not overwrite invalid saved settings (case %#)',
    async (raw) => {
      const { storage, first } = tabs();
      storage.data.set(TRUST_KEY, raw);
      expect(await first.mutate(trust(B))).toBe('tab-only');
      expect(storage.setItem).not.toHaveBeenCalled();
      expect(storage.data.get(TRUST_KEY)).toBe(raw);
      expect(first.getSnapshot()).toMatchObject({
        saved: { devices: [] },
        settings: { devices: [B] },
        warning: expect.stringContaining('No saved trust entries are active'),
      });
    },
  );

  it('does not write after a denied read, and preserves the explicit local choice', async () => {
    const { storage, first } = tabs([A]);
    storage.getItem.mockImplementation(() => {
      throw new Error('denied');
    });
    expect(await first.mutate(untrust(A))).toBe('tab-only');
    expect(storage.setItem).not.toHaveBeenCalled();
    expect(first.getSnapshot()).toMatchObject({
      settings: { devices: [] },
      overrides: [untrust(A)],
      warning: expect.any(String),
    });
  });

  it('keeps failed additions local across refreshes and unrelated successful operations', async () => {
    const { storage, first, second, create } = tabs([A]);
    storage.setItem.mockImplementationOnce(() => {
      throw new Error('quota');
    });
    expect(await first.mutate(trust(B))).toBe('tab-only');
    await second.mutate(untrust(A));
    first.refresh();
    expect(first.getSnapshot().settings.devices).toEqual([B]);
    expect(await first.mutate(trust(C))).toBe('saved');
    expect(storage.entries()).toEqual([C]);
    expect(create().getSnapshot().settings.devices).toEqual([C]);
    expect(first.getSnapshot()).toMatchObject({
      settings: { devices: [C, B] },
      overrides: [trust(B)],
      warning: expect.stringContaining('Tab-only'),
    });
    expect(await first.mutate(trust(B))).toBe('saved');
    expect(storage.entries()).toEqual([C, B]);
    expect(first.getSnapshot()).toMatchObject({ overrides: [], warning: null });
  });

  it('never silently saves a failed removal when an unrelated operation succeeds', async () => {
    const { storage, first } = tabs([A]);
    storage.setItem.mockImplementationOnce(() => {
      throw new Error('quota');
    });
    expect(await first.mutate(untrust(A))).toBe('tab-only');
    first.refresh();
    expect(first.getSnapshot().settings.devices).toEqual([]);
    await first.mutate(trust(B));
    expect(storage.entries()).toEqual([A, B]);
    expect(first.getSnapshot()).toMatchObject({ settings: { devices: [B] }, overrides: [untrust(A)] });
    await first.mutate(untrust(A));
    expect(storage.entries()).toEqual([B]);
    expect(first.getSnapshot().overrides).toEqual([]);
  });

  it('local overrides survive key removal, storage clearing, and later saved choices for the same identity', async () => {
    const { storage, first, second } = tabs([A]);
    storage.setItem.mockImplementationOnce(() => {
      throw new Error('quota');
    });
    await first.mutate(untrust(A));
    storage.data.delete(TRUST_KEY);
    first.refresh();
    expect(first.getSnapshot().overrides).toEqual([untrust(A)]);
    await second.mutate(trust(A));
    first.refresh();
    expect(first.getSnapshot().settings.devices).toEqual([]);
    storage.data.clear();
    first.refresh();
    expect(first.getSnapshot().overrides).toEqual([untrust(A)]);
  });

  it('a failed second choice replaces only that identity’s override; a successful explicit choice clears it', async () => {
    const storage = new MemoryStorage();
    let available = false;
    const serial = new SerialLock();
    const controller = new TrustStateController({
      storage,
      lock: {
        run: (signal, operation) =>
          available ? serial.run(signal, operation) : Promise.reject(new Error('unavailable')),
      },
    });
    await controller.mutate(trust(A));
    await controller.mutate(trust(B));
    await controller.mutate(untrust(A));
    expect(controller.getSnapshot()).toMatchObject({ settings: { devices: [B] }, overrides: [untrust(A), trust(B)] });
    available = true;
    await controller.mutate(trust(A));
    expect(controller.getSnapshot()).toMatchObject({ saved: { devices: [A] }, overrides: [trust(B)] });
  });

  it('keeps snapshots isolated from consumers, including override identities', async () => {
    const storage = new MemoryStorage();
    storage.seed([A]);
    const controller = new TrustStateController({ storage, lock: null });
    await controller.mutate(trust(B));
    const snapshot = controller.getSnapshot();
    snapshot.saved.devices.length = 0;
    snapshot.settings.devices[0]!.digest = C.digest;
    snapshot.overrides[0]!.device.digest = C.digest;
    expect(controller.getSnapshot()).toMatchObject({
      saved: { devices: [A] },
      settings: { devices: [A, B] },
      overrides: [trust(B)],
    });
  });

  it('does not turn reload or refresh into a save retry', async () => {
    const { storage, first, create } = tabs();
    storage.setItem.mockImplementationOnce(() => {
      throw new Error('quota');
    });
    await first.mutate(trust(A));
    first.refresh();
    expect(storage.setItem).toHaveBeenCalledTimes(1);
    expect(create().getSnapshot().settings.devices).toEqual([]);
  });
});

class BrowserTarget extends EventTarget {
  localStorage = new MemoryStorage();
  navigator = {
    locks: {
      request: vi.fn((_name: string, options: { signal: AbortSignal; mode: string }, operation: () => void) =>
        this.lock.run(options.signal, operation),
      ),
    },
  };
  private readonly lock = new SerialLock();
  storage(key: string | null, newValue: string | null, storageArea: MemoryStorage = this.localStorage): void {
    this.dispatchEvent(Object.assign(new Event('storage'), { key, newValue, storageArea }));
  }
}
class PageTarget extends EventTarget {
  visibilityState = 'visible';
}
function browserController() {
  const target = new BrowserTarget();
  const page = new PageTarget();
  const controller = createBrowserTrustController(target as unknown as Window, page as unknown as Document);
  return { target, page, controller };
}

describe('browser synchronization and lifecycle', () => {
  it('requests the shared origin-scoped exclusive lock with a cancellation signal', async () => {
    const { target, controller } = browserController();
    await controller.mutate(trust(A));
    expect(target.navigator.locks.request).toHaveBeenCalledWith(
      TRUST_LOCK_NAME,
      { mode: 'exclusive', signal: expect.any(AbortSignal) },
      expect.any(Function),
    );
    expect(controller.getSnapshot().settings.devices).toEqual([A]);
    controller.dispose();
  });

  it('refreshes other-tab changes by reading current storage, never an event’s stale newValue', () => {
    const { target, controller } = browserController();
    target.localStorage.seed([B]);
    target.storage(TRUST_KEY, serialized([A]));
    expect(controller.getSnapshot().settings.devices).toEqual([B]);
    expect(target.localStorage.setItem).not.toHaveBeenCalled();
    controller.dispose();
  });

  it.each([TRUST_KEY, null])('handles trust-key deletion / storage clearing: %s', (key) => {
    const { target, controller } = browserController();
    target.localStorage.seed([A]);
    controller.refresh();
    target.localStorage.data.clear();
    target.storage(key, null);
    expect(controller.getSnapshot().settings.devices).toEqual([]);
    controller.dispose();
  });

  it('ignores unrelated keys and other storage areas', () => {
    const { target, controller } = browserController();
    const listener = vi.fn();
    controller.subscribe(listener);
    target.localStorage.getItem.mockClear();
    target.storage('wardrive-atlas.notable-rules.v1', serialized([A]));
    target.storage(TRUST_KEY, serialized([A]), new MemoryStorage());
    expect(target.localStorage.getItem).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledTimes(1);
    controller.dispose();
  });

  it('refreshes on focus, visible activation, and page restoration, but not when hidden', () => {
    const { target, page, controller } = browserController();
    target.localStorage.seed([A]);
    target.dispatchEvent(new Event('focus'));
    expect(controller.getSnapshot().settings.devices).toEqual([A]);
    target.localStorage.seed([B]);
    page.visibilityState = 'hidden';
    page.dispatchEvent(new Event('visibilitychange'));
    expect(controller.getSnapshot().settings.devices).toEqual([A]);
    page.visibilityState = 'visible';
    page.dispatchEvent(new Event('visibilitychange'));
    expect(controller.getSnapshot().settings.devices).toEqual([B]);
    target.localStorage.seed([C]);
    target.dispatchEvent(new Event('pageshow'));
    expect(controller.getSnapshot().settings.devices).toEqual([C]);
    controller.dispose();
  });

  it('keeps local overrides when browser storage events refresh the saved list', async () => {
    const { target, controller } = browserController();
    target.localStorage.setItem.mockImplementationOnce(() => {
      throw new Error('quota');
    });
    await controller.mutate(trust(A));
    target.localStorage.seed([B]);
    target.storage(TRUST_KEY, serialized([B]));
    expect(controller.getSnapshot()).toMatchObject({
      saved: { devices: [B] },
      settings: { devices: [B, A] },
      overrides: [trust(A)],
    });
    controller.dispose();
  });

  it('treats inaccessible browser storage and missing locks as tab-only, without throwing at startup', async () => {
    const target = new BrowserTarget();
    Object.defineProperty(target.navigator, 'locks', {
      get: () => {
        throw new Error('denied');
      },
    });
    Object.defineProperty(target, 'localStorage', {
      get: () => {
        throw new Error('denied');
      },
    });
    const controller = createBrowserTrustController(
      target as unknown as Window,
      new PageTarget() as unknown as Document,
    );
    expect(controller.getSnapshot().warning).toContain('No saved trust entries');
    expect(await controller.mutate(trust(A))).toBe('tab-only');
    expect(controller.getSnapshot().settings.devices).toEqual([A]);
    controller.dispose();
  });

  it('unsubscribes state listeners and removes all event listeners on cleanup', () => {
    const { target, page, controller } = browserController();
    const listener = vi.fn();
    const unsubscribe = controller.subscribe(listener);
    unsubscribe();
    controller.refresh();
    expect(listener).toHaveBeenCalledTimes(1);
    const removeWindow = vi.spyOn(target, 'removeEventListener');
    const removePage = vi.spyOn(page, 'removeEventListener');
    controller.dispose();
    controller.dispose();
    target.localStorage.getItem.mockClear();
    target.storage(TRUST_KEY, null);
    target.dispatchEvent(new Event('focus'));
    target.dispatchEvent(new Event('pageshow'));
    page.dispatchEvent(new Event('visibilitychange'));
    controller.refresh();
    controller.subscribe(listener);
    expect(removeWindow.mock.calls.map(([event]) => event)).toEqual(['storage', 'focus', 'pageshow']);
    expect(removePage.mock.calls.map(([event]) => event)).toEqual(['visibilitychange']);
    expect(target.localStorage.getItem).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it('aborts pending acquisition during disposal and cannot write in a late callback', async () => {
    const storage = new MemoryStorage();
    let callback: (() => void) | undefined;
    const controller = new TrustStateController({
      storage,
      lock: {
        run: (_, operation) => {
          callback = operation;
          return new Promise(() => {});
        },
      },
    });
    const listener = vi.fn();
    controller.subscribe(listener);
    const pending = controller.mutate(trust(A));
    controller.dispose();
    expect(await pending).toBe('rejected');
    expect(callback).toThrow();
    expect(storage.setItem).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledTimes(2);
    expect(await controller.mutate(trust(A))).toBe('rejected');
  });

  it('allows a pending-state subscriber to dispose before acquisition without a late write', async () => {
    const { storage, first } = tabs();
    first.subscribe((state) => {
      if (state.pending) first.dispose();
    });
    expect(await first.mutate(trust(A))).toBe('rejected');
    expect(storage.setItem).not.toHaveBeenCalled();
  });
});
