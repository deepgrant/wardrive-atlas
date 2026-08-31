import { z } from 'zod';
import { SignalTypeSchema } from './csv';

export const CategorySchema = z.enum(['flock', 'axon', 'meta']);
export type Category = z.infer<typeof CategorySchema>;
export const CATEGORY_LABELS: Record<Category, string> = { flock: 'Flock', axon: 'Axon', meta: 'Meta glasses' };
export const CATEGORIES = CategorySchema.options;

export const RuleSchema = z.object({
  id: z.string().min(1),
  category: CategorySchema,
  protocols: z.array(SignalTypeSchema).min(1),
  match: z.discriminatedUnion('kind', [
    z.object({
      kind: z.literal('prefix'),
      value: z.string().regex(/^[0-9A-F]{6}$/),
      allowLocal: z.boolean().default(false),
    }),
    z.object({ kind: z.literal('manufacturer'), value: z.string().regex(/^[0-9A-F]{4}$/) }),
    z.object({ kind: z.literal('name'), value: z.string().min(1), mode: z.enum(['starts', 'contains', 'exact']) }),
    z.object({ kind: z.literal('serial') }),
  ]),
  research: z.boolean().default(false),
  custom: z.boolean().default(false),
  explanation: z.string().min(1),
  source: z.string().url().nullable(),
  sourceLabel: z.string().min(1),
});
export type DetectionRule = z.infer<typeof RuleSchema>;
export const CatalogSchema = z.object({
  version: z.string().min(1),
  reviewed: z.iso.date(),
  rules: z
    .array(RuleSchema)
    .refine((rules) => new Set(rules.map((rule) => rule.id)).size === rules.length, 'Duplicate rule IDs'),
});

const biscuit = {
  source: 'https://codehedge.github.io/Biscuit-Wiki/3rd-party-integration/wardrive.html',
  sourceLabel: 'Biscuit Wiki',
};
const ouiSpy = {
  source: 'https://github.com/colonelpanichacks/oui-spy-unified-blue',
  sourceLabel: 'OUI SPY detector research',
};

// Reviewed snapshot of the 2026-07-16 upstream list plus DeFlockJoplin's
// experimental local prefix. Data facts only; matcher implementation is original.
// Excludes withdrawn F8A2D6, CCCCCC, 000CE7, 942A6F, F4E2C6 and 6CCDD6.
const researchPrefixes = [
  '70C94E',
  '3C9180',
  'D8F3BC',
  '803049',
  'B83532',
  '145AFC',
  '744CA1',
  '083A88',
  '9C2F9D',
  'C03532',
  '940853',
  'E4AAEA',
  'F46ADD',
  'E00AF6',
  '24B2B9',
  '00F48D',
  'D03957',
  'E8D0FC',
  'E04F43',
  'B81EA4',
  '700894',
  '588E81',
  'EC1BBD',
  '3C71BF',
  '5800E3',
  '9035EA',
  '5C93A2',
  '646E69',
  '4827EA',
  'A4CF12',
  '14B5CD',
  '826BF2',
];

export const BUILTIN_CATALOG = CatalogSchema.parse({
  version: '2026-08-30.1',
  reviewed: '2026-08-30',
  rules: [
    {
      id: 'flock-oui',
      category: 'flock',
      protocols: ['Wi-Fi', 'BLE'],
      match: { kind: 'prefix', value: 'B41E52' },
      explanation:
        'Published Flock vendor prefix. A prefix identifies an address allocation, not the physical device type.',
      ...biscuit,
    },
    {
      id: 'flock-company',
      category: 'flock',
      protocols: ['BLE'],
      match: { kind: 'manufacturer', value: '09C8' },
      explanation:
        'The exported Bluetooth manufacturer ID matches the published Flock signature. Advertisement payload was not available for verification.',
      ...biscuit,
    },
    ...['Penguin-', 'Flock-', 'pigvision', 'FS Ext Battery'].map((name, index) => ({
      id: `flock-name-${index}`,
      category: 'flock',
      protocols: ['BLE'],
      match: { kind: 'name', value: name, mode: index < 2 ? 'starts' : 'exact' },
      explanation:
        'The Bluetooth name matches a published Flock naming pattern. Device names can be changed or imitated.',
      ...biscuit,
    })),
    {
      id: 'axon-oui',
      category: 'axon',
      protocols: ['BLE'],
      match: { kind: 'prefix', value: '0025DF' },
      explanation: 'Published Axon/TASER vendor prefix. It does not establish a body camera or its owner.',
      ...ouiSpy,
    },
    {
      id: 'axon-company',
      category: 'axon',
      protocols: ['BLE'],
      match: { kind: 'manufacturer', value: '034D' },
      explanation:
        'The exported Bluetooth manufacturer ID matches TASER International. No service UUID or payload verification is possible from this CSV.',
      ...ouiSpy,
    },
    ...['Ray-Ban', 'Wayfarer', 'Oakley Meta'].map((name, index) => ({
      id: `meta-name-${index}`,
      category: 'meta',
      protocols: ['BLE'],
      match: { kind: 'name', value: name, mode: 'contains' },
      explanation:
        'The Bluetooth name matches a published smart-glasses naming pattern. The stronger manufacturer-plus-service signature is unavailable in this CSV.',
      ...ouiSpy,
    })),
    {
      id: 'flock-serial',
      category: 'flock',
      protocols: ['BLE'],
      match: { kind: 'serial' },
      research: true,
      explanation:
        'A ten-digit Bluetooth name resembles a serial number. Many unrelated devices can use this pattern; this is only a research lead.',
      ...biscuit,
    },
    ...researchPrefixes.map((prefix) => ({
      id: `flock-research-${prefix}`,
      category: 'flock',
      protocols: ['Wi-Fi'],
      match: { kind: 'prefix', value: prefix, allowLocal: prefix === '826BF2' },
      research: true,
      explanation:
        prefix === '826BF2'
          ? 'Experimental, locally administered address prefix reported by DeFlockJoplin. This is not an IEEE vendor allocation and may collide with unrelated devices.'
          : 'Community-reported Wi-Fi hardware prefix. Shared consumer chipsets can match; CSV does not retain the probe behavior needed to strengthen this lead.',
      source: 'https://github.com/colonelpanichacks/flock-you/blob/main/datasets/NitekryDPaul_wifi_ouis.md',
      sourceLabel: 'NitekryDPaul / DeFlockJoplin research · July 2026 snapshot',
    })),
  ],
});
