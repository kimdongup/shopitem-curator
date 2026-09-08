// Requires: npm ci --prefix server/browser --ignore-scripts
// CURATOR_SMOKE_URL and CURATOR_SMOKE_PASSWORD are never printed or persisted.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('../server/browser/node_modules/playwright-core');
let stage = 'configuration';

(async () => {
  const base = process.env.CURATOR_SMOKE_URL;
  const password = process.env.CURATOR_SMOKE_PASSWORD;
  if (!base || !password) throw new Error('Set smoke URL and password in the environment.');
  const browser = await chromium.launch({headless: true,
    executablePath: process.env.CURATOR_BROWSER_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const context = await browser.newContext({viewport: {width: 1440, height: 1050}});
    const page = await context.newPage();
    const errors = [];
    const externalOrigins = new Set();
    page.on('request', request => {
      const url = new URL(request.url());
      if (/^https?:$/.test(url.protocol) && url.origin !== new URL(base).origin) externalOrigins.add(url.origin);
    });
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {
      if (message.type() === 'error' && /Content Security Policy|Refused to|WebAssembly|canvaskit/i.test(message.text())) errors.push(message.text());
    });
    stage = 'readiness and anonymous access';
    assert.equal((await context.request.get(base + '/ready')).status(), 200);
    assert.equal((await context.request.get(base + '/v1/documents')).status(), 401);
    stage = 'login form';
    await page.goto(base + '/login');
    await page.locator('input[name=password]').fill(password);
    // The app starts document OCR after login. Wait for that request before
    // starting the independent engine check (the free server runs one job).
    const initialProject = page.waitForResponse(response =>
      new URL(response.url()).pathname === '/v1/browser-projects/open' &&
      response.request().method() === 'POST', {timeout: 60000});
    const [, , opened] = await Promise.all([page.waitForURL(base + '/'),
      page.getByRole('button', {name: '로그인', exact: true}).click(), initialProject]);
    assert.equal(opened.status(), 200);
    stage = 'authenticated document list';
    // Check actual same-origin browser cookies, not manually injected auth.
    const documents = await page.evaluate(async () => {
      const response = await fetch('/v1/documents');
      return {status: response.status, data: await response.json()};
    });
    assert.equal(documents.status, 200);
    assert.ok(documents.data.documents.length > 0);
    stage = 'uncached sample OCR';
    // Project/open may return persisted entries without calling the engine.
    // Exercise actual recognition before checking the project workflow.
    const ocr = await page.evaluate(async imageBase64 => {
      const response = await fetch('/v1/ocr/extract', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({source_image_path: 'assets/images/new.jpg', image_base64: imageBase64}),
      });
      return {status: response.status, data: await response.json()};
    }, fs.readFileSync(path.join(__dirname, '../assets/images/new.jpg')).toString('base64'));
    console.log(`Sample OCR: HTTP ${ocr.status}, ${ocr.data.items?.length ?? 0} items.`);
    assert.equal(ocr.status, 200);
    stage = 'uncached sample OCR contents';
    assert.deepEqual(ocr.data.items.map(item => item.clean_name),
      ['Hand sanitizer', 'White Board Markers', 'Backpack']);
    stage = 'sample project';
    const project = await page.evaluate(async () => {
      const response = await fetch('/v1/browser-projects/open', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({source_image_path: 'assets/images/new.jpg'}),
      });
      return {status: response.status, data: await response.json()};
    });
    assert.equal(project.status, 200);
    assert.ok(project.data.entries.length > 0);
    stage = 'Flutter rendering';
    await page.locator('flutter-view').waitFor({timeout: 45000});
    // Flutter places its canvas inside a shadow root; Playwright pierces it.
    await page.locator('canvas').first().waitFor({timeout: 45000});
    await page.screenshot({path: 'build/preview-browser-smoke.png'});
    stage = 'browser security policy';
    assert.deepEqual(errors, []);
    assert.equal(externalOrigins.size, 0);
    stage = 'logout';
    await page.goto(base + '/logout');
    await Promise.all([page.waitForURL(base + '/login'), page.getByRole('button', {name: '로그아웃 확인'}).click()]);
    assert.equal((await context.request.get(base + '/v1/documents')).status(), 401);
    console.log('PASS: login, protected API, real sample OCR, Flutter canvas, CSP and logout.');
  } finally { await browser.close(); }
})().catch(error => {
  console.error(`Preview browser smoke failed at ${stage} (${error.name}); credentials and response bodies omitted.`);
  process.exitCode = 1;
});
