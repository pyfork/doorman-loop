// one test per stand-in page, width and theme; plus one that every page template has a stand-in
// (a stand-in named <template> or <template>_<state>).
// senior-lead-Opus5.5-agent, 2026-11-02
import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const pages = fs.readFileSync(path.join(root, 'acceptance/screens/pages.txt'), 'utf8')
  .split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'))
  .map(l => { const [name, ...rest] = l.split(/\s+/); return { name, target: rest.join(' ') }; });
const base = process.env.SCREENS_BASE_URL || '';
const url = t => /^https?:/.test(t) ? t : base ? base + t : 'file://' + path.join(root, t);

test('every page template has a stand-in', () => {
  const glob = process.env.SCREENS_TEMPLATES;
  test.skip(!glob, 'SCREENS_TEMPLATES not set');
  const missing = fs.globSync(glob, { cwd: root }).map(f => path.basename(f).replace(/\.[^.]+$/, ''))
    .filter(n => !n.startsWith('_') && !pages.some(p => p.name === n || p.name.startsWith(n + '_')));
  expect(missing, 'page templates with no stand-in in acceptance/screens/pages.txt').toEqual([]);
});

for (const p of pages) for (const width of [390, 1280]) for (const theme of ['light', 'dark']) {
  test(`${p.name}-${width}-${theme}`, async ({ page }) => {
    await page.clock.install({ time: new Date('2026-01-01T09:00:00Z') });
    await page.emulateMedia({ colorScheme: theme, reducedMotion: 'reduce' });
    await page.setViewportSize({ width, height: 900 });
    await page.goto(url(p.target), { waitUntil: 'networkidle' });
    await page.evaluate(() => document.fonts.ready);
    await expect(page).toHaveScreenshot(`${p.name}-${width}-${theme}.png`, { fullPage: true });
  });
}
