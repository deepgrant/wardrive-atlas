import { CoTravelResponseSchema, type CoTravelAnalysis, type CoTravelRequest } from './co-travel-schema';

export interface AnalysisWorker {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  onerror: ((event: ErrorEvent) => void) | null;
  postMessage(message: CoTravelRequest): void;
  terminate(): void;
}

// Terminate superseded work, not just its callback: a long old capture must not
// delay a newly filtered request. Also reject late queued responses by generation.
export class CoTravelRunner {
  private worker: AnalysisWorker | null = null;
  private generation = 0;
  constructor(private readonly createWorker: () => AnalysisWorker) {}
  cancel(): void {
    this.generation++;
    this.worker?.terminate();
    this.worker = null;
  }
  run(
    input: Omit<CoTravelRequest, 'requestId'>,
    onResult: (result: CoTravelAnalysis) => void,
    onError: (message: string) => void,
  ): void {
    this.cancel();
    const requestId = this.generation;
    try {
      const worker = this.createWorker();
      this.worker = worker;
      worker.onmessage = (event) => {
        if (requestId !== this.generation) return;
        const parsed = CoTravelResponseSchema.safeParse(event.data);
        if (
          !parsed.success ||
          (parsed.data.requestId !== requestId && !(parsed.data.kind === 'error' && parsed.data.requestId === 0))
        ) {
          this.cancel();
          onError('Movement analysis returned an invalid result. Please retry.');
          return;
        }
        this.cancel();
        if (parsed.data.kind === 'error') onError(parsed.data.message);
        else onResult(parsed.data.result);
      };
      worker.onerror = () => {
        if (requestId !== this.generation) return;
        this.cancel();
        onError('The local analysis worker could not run. Please retry or reload the app.');
      };
      worker.postMessage({ ...input, requestId });
    } catch {
      this.cancel();
      onError('The local analysis worker could not start. Please retry or reload the app.');
    }
  }
}
