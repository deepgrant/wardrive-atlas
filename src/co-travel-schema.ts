import { z } from 'zod';
import { SignalTypeSchema, WardriveRecordSchema } from './csv';
import { CustomPrefixSchema } from './notable';

export const SensitivitySchema = z.enum(['high', 'medium', 'low']);
export type Sensitivity = z.infer<typeof SensitivitySchema>;
export const CoTravelSettingsSchema = z.strictObject({ sensitivity: SensitivitySchema.default('medium') });
export const THRESHOLDS = {
  high: { sightings: 2, locations: 2, minutes: 5, meters: 250 },
  medium: { sightings: 3, locations: 2, minutes: 10, meters: 500 },
  low: { sightings: 4, locations: 2, minutes: 20, meters: 750 },
} as const;

const CountSchema = z.number().int().nonnegative();
const TimeSchema = z.number().finite();
export const EvidenceWindowSchema = z.strictObject({
  first: TimeSchema,
  last: TimeSchema,
  sightingIds: z.array(z.string()),
  locations: CountSchema,
  travelMeters: z.number().finite().nonnegative(),
  qualifies: z.boolean(),
});
export type EvidenceWindow = z.infer<typeof EvidenceWindowSchema>;
export const CoTravelAssessmentSchema = z.strictObject({
  id: z.string().min(1),
  representativeId: z.string().min(1),
  type: SignalTypeSchema,
  recordIds: z.array(z.string()),
  sightings: z.array(z.strictObject({ recordId: z.string(), location: CountSchema })),
  locations: CountSchema,
  sessions: CountSchema,
  first: TimeSchema.nullable(),
  last: TimeSchema.nullable(),
  context: z.enum(['wifi', 'camera']).nullable(),
  contextLabels: z.array(z.enum(['flock', 'axon'])),
  window: EvidenceWindowSchema.nullable(),
});
export type CoTravelAssessment = z.infer<typeof CoTravelAssessmentSchema>;
export const CoverageSchema = z.strictObject({
  total: CountSchema,
  eligible: CountSchema,
  excluded: CountSchema,
  invalidAddress: CountSchema,
  invalidTime: CountSchema,
  invalidFix: CountSchema,
  invalidAccuracy: CountSchema,
  duplicates: CountSchema,
  independent: CountSchema,
  locations: CountSchema,
  sessions: CountSchema,
});
export const CoTravelAnalysisSchema = z.strictObject({
  assessments: z.array(CoTravelAssessmentSchema),
  coverage: CoverageSchema,
});
export type CoTravelAnalysis = z.infer<typeof CoTravelAnalysisSchema>;
export const CoTravelRequestSchema = z.strictObject({
  requestId: CountSchema,
  records: z.array(WardriveRecordSchema),
  settings: CoTravelSettingsSchema,
  customPrefixes: z.array(CustomPrefixSchema).max(500),
});
export type CoTravelRequest = z.infer<typeof CoTravelRequestSchema>;
export const CoTravelResponseSchema = z.discriminatedUnion('kind', [
  z.strictObject({ kind: z.literal('result'), requestId: CountSchema, result: CoTravelAnalysisSchema }),
  z.strictObject({ kind: z.literal('error'), requestId: CountSchema, message: z.string() }),
]);
export type CoTravelResponse = z.infer<typeof CoTravelResponseSchema>;
export const CoTravelViewSchema = z.enum(['candidates', 'observed', 'context', 'trusted']);
export type CoTravelView = z.infer<typeof CoTravelViewSchema>;

export function emptyCoTravelAnalysis(): CoTravelAnalysis {
  return {
    assessments: [],
    coverage: {
      total: 0,
      eligible: 0,
      excluded: 0,
      invalidAddress: 0,
      invalidTime: 0,
      invalidFix: 0,
      invalidAccuracy: 0,
      duplicates: 0,
      independent: 0,
      locations: 0,
      sessions: 0,
    },
  };
}
