// Renders docs/img/*.png from visuals.html.
// Usage: node docs/img/src/render.cjs <path to an installed playwright package>
//   e.g. node docs/img/src/render.cjs ./node_modules/playwright
const path = require('path');
const { chromium } = require(process.argv[2] || 'playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 }, deviceScaleFactor: 2 });
  await page.goto('file://' + path.join(__dirname, 'visuals.html'));
  await page.waitForTimeout(400);
  for (const id of ['architecture', 'origin', 'where-it-pays']) {
    const el = await page.$('#' + id);
    const empty = await el.evaluate(e => e.querySelector('svg') && !e.querySelector('svg').childElementCount);
    if (empty) { console.log('skip ' + id + ' (no data yet)'); continue; }
    await el.screenshot({ path: path.join(__dirname, '..', id + '.png') });
    console.log('wrote docs/img/' + id + '.png');
  }
  await browser.close();
})();
