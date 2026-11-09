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
  expect: { toHaveScreenshot: { maxDiffPixels: 0, animations: 'disabled', caret: 'hide' } },
});
