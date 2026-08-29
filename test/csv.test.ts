import { describe, expect, it } from 'vitest';
import { findHeaderRow, getBand, getSecurity, parseCsvRows, parseWardriveCsv, WardriveRecordSchema } from '../src/csv';

describe('CSV parsing', () => {
  it('parses quoted commas, escaped quotes, and newlines', () => {
    const rows = parseCsvRows('SSID,Note\n"Cafe, North","Say ""hello""\nagain"');
    expect(rows).toEqual([
      ['SSID', 'Note'],
      ['Cafe, North', 'Say "hello"\nagain'],
    ]);
  });

  it('finds a header after a Biscuit/WiGLE metadata line', () => {
    const rows = parseCsvRows(
      'WigleWifi-1.6,appRelease=1\nMAC,SSID,AuthMode,CurrentLatitude,CurrentLongitude\naa,home,WPA2,1,2',
    );
    expect(findHeaderRow(rows)).toBe(1);
  });

  it('normalizes and validates a supported wardrive export', () => {
    const csv = [
      'WigleWifi-1.6,appRelease=Biscuit',
      'MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type',
      'AA:BB:CC:DD:EE:FF,"Cafe, North",WPA2,2026-08-29 10:30:00,6,-54,40.1,-73.2,12.4,4.2,WIFI',
      '11:22:33:44:55:66,Beacon,,2026-08-29 10:31:00,37,-70,40.2,-73.3,,,BLE',
    ].join('\n');
    const records = parseWardriveCsv(csv, 'morning.csv');

    expect(records).toHaveLength(2);
    expect(WardriveRecordSchema.safeParse(records[0]).success).toBe(true);
    expect(records[0]?.ssid).toBe('Cafe, North');
    expect(records[0]?.band).toBe('2.4 GHz');
    expect(records[0]?.security).toBe('WPA2');
    expect(records[1]?.type).toBe('BLE');
    expect(records[1]?.band).toBe('Bluetooth');
  });

  it('classifies common bands and security modes', () => {
    expect(getBand(11, 'WIFI')).toBe('2.4 GHz');
    expect(getBand(149, 'WIFI')).toBe('5 GHz');
    expect(getBand(213, 'WIFI')).toBe('6 GHz');
    expect(getSecurity('[WPA3-SAE-CCMP]')).toBe('WPA3');
    expect(getSecurity('[ESS]')).toBe('Other');
    expect(getSecurity('OPEN')).toBe('Open');
  });

  it('rejects files without recognizable headers', () => {
    expect(() => parseWardriveCsv('name,value\nfoo,bar')).toThrow(/No supported CSV header/);
  });

  it('rejects observations outside valid coordinate ranges', () => {
    const csv = 'MAC,SSID,CurrentLatitude,CurrentLongitude\naa,home,95,-200';
    expect(() => parseWardriveCsv(csv)).toThrow(/no rows with valid latitude and longitude/i);
  });
});
