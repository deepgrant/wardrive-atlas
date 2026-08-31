import { TRUST_KEY, TRUST_LOCK_NAME, TrustStateController, type TrustLock } from './co-travel-trust';

/** Browser wiring stays outside the controller so coordination can be tested without a browser. */
export function createBrowserTrustController(target: Window = window, page: Document = document): TrustStateController {
  let lock: TrustLock | null = null;
  try {
    const locks = target.navigator.locks;
    if (locks)
      lock = { run: (signal, operation) => locks.request(TRUST_LOCK_NAME, { mode: 'exclusive', signal }, operation) };
  } catch {
    // No unlocked fallback: the controller keeps an explicit tab-only override.
  }
  return new TrustStateController({
    storage: {
      getItem: (key) => target.localStorage.getItem(key),
      setItem: (key, value) => target.localStorage.setItem(key, value),
    },
    lock,
    subscribeRefresh: (refresh) => {
      const onStorage = (event: StorageEvent): void => {
        if (event.key !== TRUST_KEY && event.key !== null) return;
        try {
          if (event.storageArea !== target.localStorage) return;
        } catch {
          // Reading again will surface inaccessible storage without trusting stale data.
        }
        refresh();
      };
      const onVisibility = (): void => {
        if (page.visibilityState === 'visible') refresh();
      };
      target.addEventListener('storage', onStorage);
      target.addEventListener('focus', refresh);
      target.addEventListener('pageshow', refresh);
      page.addEventListener('visibilitychange', onVisibility);
      return () => {
        target.removeEventListener('storage', onStorage);
        target.removeEventListener('focus', refresh);
        target.removeEventListener('pageshow', refresh);
        page.removeEventListener('visibilitychange', onVisibility);
      };
    },
  });
}
