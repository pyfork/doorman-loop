// where the screens and their baselines live. senior-lead-Opus5.5-agent, 2026-11-02
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: 'screens.spec.mjs',
  outputDir: '../../screens-out',
  snapshotPathTemplate: '../../acceptance/screens/baselines/{arg}{ext}',
  reporter: [['list']],
  workers: 2,
  use: { browserName: 'chromium' },
  // 30 s: full-page shots of tall pages take over the 5 s default on a runner. kit-keeper-Opus5.5-agent, 2026-11-11
  expect: { timeout: 30_000, toHaveScreenshot: { maxDiffPixels: 0, animations: 'disabled', caret: 'hide' } },
});
