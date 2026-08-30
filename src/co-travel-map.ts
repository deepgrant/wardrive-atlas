import type { FeatureCollection, Point, LineString } from 'geojson';
import type { WardriveRecord } from './csv';
import type { CoTravelAssessment } from './co-travel-schema';
import { PATH_GAP_MS, usablePosition } from './co-travel';

// Only opaque, tab-local identifiers and display state enter map properties.
export function movementPins(
  assessments: readonly CoTravelAssessment[],
  records: ReadonlyMap<string, WardriveRecord>,
): FeatureCollection<Point> {
  return {
    type: 'FeatureCollection',
    features: assessments.flatMap((assessment) => {
      const sessions = new Map<string, WardriveRecord>();
      for (const sighting of assessment.sightings) {
        const record = records.get(sighting.recordId);
        if (record) sessions.set(record.session, record);
      }
      return [...sessions.values()].map((record) => ({
        type: 'Feature' as const,
        properties: {
          assessmentId: assessment.id,
          icon: assessment.window?.qualifies ? 'movement-solid' : 'movement-outline',
        },
        geometry: { type: 'Point' as const, coordinates: [record.longitude, record.latitude] },
      }));
    }),
  };
}

export function movementSelection(
  assessment: CoTravelAssessment | undefined,
  records: ReadonlyMap<string, WardriveRecord>,
): { points: FeatureCollection<Point>; paths: FeatureCollection<LineString> } {
  const points: FeatureCollection<Point> = { type: 'FeatureCollection', features: [] };
  const paths: FeatureCollection<LineString> = { type: 'FeatureCollection', features: [] };
  if (!assessment) return { points, paths };
  // Highlight all filtered sightings, but draw paths only from eligible independent
  // evidence, never across files or gaps. Excluded rows cannot imply movement.
  for (const id of assessment.recordIds) {
    const record = records.get(id);
    if (!record || !usablePosition(record)) continue;
    points.features.push({
      type: 'Feature',
      properties: {},
      geometry: { type: 'Point', coordinates: [record.longitude, record.latitude] },
    });
  }
  const sessions = new Map<string, WardriveRecord[]>();
  for (const sighting of assessment.sightings) {
    const record = records.get(sighting.recordId);
    if (!record) continue;
    const rows = sessions.get(record.session) ?? [];
    rows.push(record);
    sessions.set(record.session, rows);
  }
  let sessionIndex = 0;
  for (const rows of sessions.values()) {
    rows.sort((a, b) => a.timestamp! - b.timestamp!);
    let segment: number[][] = [];
    const flush = (): void => {
      if (segment.length > 1)
        paths.features.push({
          type: 'Feature',
          properties: { sessionIndex },
          geometry: { type: 'LineString', coordinates: segment },
        });
      segment = [];
    };
    rows.forEach((record, index) => {
      if (index && record.timestamp! - rows[index - 1]!.timestamp! > PATH_GAP_MS) flush();
      segment.push([record.longitude, record.latitude]);
    });
    flush();
    sessionIndex++;
  }
  return { points, paths };
}
