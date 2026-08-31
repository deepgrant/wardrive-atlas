import { analyzeCoTravel } from './co-travel';
import { CoTravelRequestSchema, CoTravelResponseSchema, type CoTravelResponse } from './co-travel-schema';

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  postMessage(message: CoTravelResponse): void;
};
scope.onmessage = (event) => {
  const parsed = CoTravelRequestSchema.safeParse(event.data);
  if (!parsed.success) {
    scope.postMessage({ kind: 'error', requestId: 0, message: 'Movement analysis received unsupported data.' });
    return;
  }
  const request = parsed.data;
  try {
    const result = analyzeCoTravel(request.records, request.settings.sensitivity, request.customPrefixes);
    scope.postMessage(CoTravelResponseSchema.parse({ kind: 'result', requestId: request.requestId, result }));
  } catch {
    scope.postMessage({
      kind: 'error',
      requestId: request.requestId,
      message: 'Movement analysis could not finish. Your imported observations are unchanged.',
    });
  }
};
