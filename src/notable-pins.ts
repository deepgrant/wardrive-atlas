import type { Map } from 'maplibre-gl';
import { CATEGORIES } from './notable-rules';

// Local vector paths rendered into sprite images: no icon/font network requests.
const glyphs = {
  flock: 'M13 18h16l7 5v8l-7-3H13z M20 28v9m-5 0h10 M29 20v7',
  axon: 'M17 13h14v25H17z M20 16h8 M20 32h8 M24 21a4 4 0 1 0 0 8a4 4 0 1 0 0-8',
  meta: 'M21 25a6 6 0 1 0-12 0a6 6 0 1 0 12 0 M39 25a6 6 0 1 0-12 0a6 6 0 1 0 12 0 M21 24q3-3 6 0 M9 24l-2-5m32 5l2-5',
  multiple: 'M24 14v20 M14 24h20 M17 17l14 14m0-14L17 31',
};

export function addNotableIcons(map: Map): void {
  for (const category of [...CATEGORIES, 'multiple'] as const) {
    for (const weak of [false, true]) {
      const id = `notable-${category}-${weak ? 'weak' : 'solid'}`;
      if (map.hasImage(id)) continue;
      const canvas = document.createElement('canvas');
      canvas.width = 96;
      canvas.height = 112;
      const ctx = canvas.getContext('2d');
      if (!ctx) continue;
      ctx.scale(2, 2);
      const pin = new Path2D('M24 52C21 45 5 36 5 24a19 19 0 1 1 38 0c0 12-16 21-19 28Z');
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 6;
      ctx.lineJoin = 'round';
      ctx.stroke(pin);
      ctx.fillStyle = weak ? '#f7faf7' : '#172a46';
      ctx.fill(pin);
      ctx.strokeStyle = '#172a46';
      ctx.lineWidth = 2;
      if (weak) ctx.setLineDash([3, 2]);
      ctx.stroke(pin);
      ctx.setLineDash([]);
      ctx.strokeStyle = weak ? '#172a46' : '#ffffff';
      ctx.lineWidth = 1.8;
      ctx.lineCap = 'round';
      ctx.stroke(new Path2D(glyphs[category]));
      map.addImage(id, ctx.getImageData(0, 0, 96, 112), { pixelRatio: 2 });
    }
  }
}
