const fs = require('node:fs');
const dns = require('node:dns').promises;
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const {extractProducts} = require('./product_metadata.cjs');
const ALLOWED = new Set(['target.com', 'www.target.com', 'redsky.target.com', 'target.scene7.com']);

function allowedUrl(value) {
  try { const u = new URL(value); return u.protocol === 'https:' && !u.username && !u.password && !u.port && ALLOWED.has(u.hostname); }
  catch { return false; }
}
function publicAddress(value) {
  // Resolve only the fixed allowlist and reject non-public IPv4/IPv6 answers.
  if (value.includes(':')) {
    const v = value.toLowerCase();
    if (v.startsWith('::ffff:')) return publicAddress(v.slice(7));
    return /^[23][0-9a-f]{0,3}:/.test(v) && !v.startsWith('2001:db8:');
  }
  const p = value.split('.').map(Number);
  return p.length === 4 && p.every(n => Number.isInteger(n) && n >= 0 && n <= 255) &&
    ![0, 10, 127].includes(p[0]) && p[0] < 224 &&
    !(p[0] === 169 && p[1] === 254) && !(p[0] === 172 && p[1] >= 16 && p[1] <= 31) &&
    !(p[0] === 192 && (p[1] === 168 || p[1] === 0 || p[1] === 2)) &&
    !(p[0] === 100 && p[1] >= 64 && p[1] <= 127) && !(p[0] === 198 && [18,19,51].includes(p[1])) &&
    !(p[0] === 203 && p[1] === 0);
}
async function probe(executable) {
  let version = '';
  if (typeof executable === 'string' && fs.existsSync(executable)) {
    try {
      const result = await promisify(execFile)(executable, ['--version'], {timeout: 4000, maxBuffer: 4096});
      version = /\b\d+\.\d+\.\d+\.\d+\b/.exec(result.stdout)?.[0] ?? '';
    } catch { /* Missing executable is a capability result, not a startup crash. */ }
  }
  let available = false;
  try { require.resolve('playwright-core'); available = !!version; } catch { /* Install explicitly with npm ci. */ }
  return {available, chrome_version: version};
}

async function render(config, dependencies = {}) {
  if (!allowedUrl(config.url)) throw new Error('invalid_url');
  const timeout = Math.min(12000, Math.max(1000, config.timeout_ms ?? 12000));
  const {chromium} = dependencies.playwright ?? require('playwright-core');
  const addresses = new Map();
  for (const host of ALLOWED) {
    const values = await (dependencies.lookup ?? dns.lookup)(host, {all: true});
    if (!values.length || values.some(v => !publicAddress(v.address))) throw new Error('invalid_address');
    addresses.set(host, values.find(v => !v.address.includes(':'))?.address ?? values[0].address);
  }
  const rules = [...addresses].map(([host, address]) => `MAP ${host} ${address.includes(':') ? '[' + address + ']' : address}`).join(',');
  const browser = await chromium.launch({executablePath: config.executable,
    headless: true, timeout: 6000, chromiumSandbox: true,
    args: ['--disable-background-networking', '--disable-component-update', '--disable-sync',
      '--force-webrtc-ip-handling-policy=disable_non_proxied_udp', '--host-resolver-rules=' + rules],
    ...(config.proxy ? {proxy: config.proxy} : {}),
  });
  let context;
  try {
    const headers = Object.fromEntries(Object.entries(config.headers ?? {}).map(([k,v]) => [k.toLowerCase(),v]));
    const userAgent = headers['user-agent']; delete headers['user-agent'];
    // Real Chromium creates coherent sec-* headers; HTTP-only presets are not
    // imposed on browser navigation or XHR requests.
    for (const key of Object.keys(headers)) if (/^(sec-|referer$|accept$)/i.test(key)) delete headers[key];
    context = await browser.newContext({viewport: {width: 1280, height: 900}, locale: 'en-US',
      acceptDownloads: false, serviceWorkers: 'block', ignoreHTTPSErrors: false,
      ...(config.rotate_headers && userAgent ? {userAgent} : {}), extraHTTPHeaders: headers});
    if (config.stealth) await context.addInitScript(() => {
      Object.defineProperty(Navigator.prototype, 'webdriver', {get: () => undefined, configurable: true});
    });
    let requests = 0, jsonCount = 0, denied = null;
    const pending = [], products = new Map();
    await context.route('**/*', async route => {
      const request = route.request();
      if (denied || ++requests > 120 || !allowedUrl(request.url()) || request.method() !== 'GET' ||
          (config.denied_hosts ?? []).includes(new URL(request.url()).hostname) ||
          ['image', 'media', 'font'].includes(request.resourceType())) return route.abort();
      return route.continue();
    });
    if (context.routeWebSocket) await context.routeWebSocket('**/*', socket => socket.close());
    const page = await context.newPage();
    if (config.rotate_headers && userAgent) {
      const version = /Chrome\/([\d.]+)/.exec(userAgent)?.[1];
      if (version) {
        const windows = userAgent.includes('Windows');
        const session = await context.newCDPSession(page);
        await session.send('Network.setUserAgentOverride', {userAgent, acceptLanguage: 'en-US,en;q=0.9',
          platform: windows ? 'Win32' : 'MacIntel', userAgentMetadata: {
            brands: [{brand: 'Chromium', version: version.split('.')[0]}, {brand: 'Google Chrome', version: version.split('.')[0]}],
            fullVersion: version, platform: windows ? 'Windows' : 'macOS',
            platformVersion: windows ? '10.0.0' : '10.15.7', architecture: 'x86', model: '', mobile: false}});
      }
    }
    page.setDefaultTimeout(timeout);
    page.on('popup', popup => { void popup.close(); });
    page.on('response', response => {
      const request = response.request();
      if (!allowedUrl(response.url())) return;
      const status = response.status();
      if ([401,403,429].includes(status) && ['document','xhr','fetch'].includes(request.resourceType())) {
        denied ??= {status, host: new URL(response.url()).hostname, retry_after: response.headers()['retry-after'] ?? ''};
      }
      if (!config.observe_json || status !== 200 || !['xhr','fetch'].includes(request.resourceType()) ||
          !/\bapplication\/(?:[\w.+-]*\+)?json\b/i.test(response.headers()['content-type'] ?? '') || jsonCount >= 8) return;
      jsonCount++;
      pending.push((async () => {
        if (Number(response.headers()['content-length']) > 2 * 1024 * 1024) return;
        const body = await response.body();
        if (body.length > 2 * 1024 * 1024) return;
        for (const product of extractProducts(JSON.parse(body.toString('utf8')))) {
          if (products.size < 50) products.set(product.target_url, product);
        }
      })().catch(() => {}));
    });
    const response = await page.goto(config.url, {waitUntil: 'domcontentloaded', timeout});
    if (!response || !allowedUrl(page.url())) throw new Error('invalid_response');
    if (![401,403,429].includes(response.status())) {
      if (config.interaction) {
        // No fake clicks on product/cart/account controls and no endless scroll.
        await page.mouse.move(210, 170, {steps: 6});
        await page.mouse.move(440, 340, {steps: 9});
        await page.mouse.wheel(0, 360);
      }
      await page.waitForTimeout(config.observe_json ? 1800 : 600);
    }
    await Promise.all(pending);
    if (denied) return {status: denied.status, denied_host: denied.host, retry_after: denied.retry_after, html: '', observed_count: 0};
    let html = await page.content();
    if (Buffer.byteLength(html) > 2 * 1024 * 1024) throw new Error('response_too_large');
    if (products.size) html += '<script id="curator-observed-products" type="application/json">' +
      JSON.stringify([...products.values()]).replaceAll('<', '\\u003c') + '</script>';
    return {status: response.status(), html, observed_count: products.size};
  } finally {
    await context?.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

async function main() {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk; if (Buffer.byteLength(input) > 32768) throw new Error('invalid_input');
  }
  const config = JSON.parse(input);
  if (process.argv.includes('--probe')) {
    process.stdout.write(JSON.stringify(await probe(config.executable))); return;
  }
  let finished = false;
  const finish = result => { if (!finished) { finished = true; process.stdout.write(JSON.stringify(result)); } };
  const hardDeadline = setTimeout(() => {
    finish({status: 504, html: '', error: 'browser_timeout'});
    // Playwright's SIGTERM handler closes its browser and temporary profile.
    process.kill(process.pid, 'SIGTERM');
  }, 14000);
  try { finish(await render(config)); }
  catch { finish({status: 502, html: '', error: 'browser_unavailable_or_failed'}); }
  finally { clearTimeout(hardDeadline); }
}
module.exports = {allowedUrl, publicAddress, render, probe};
if (require.main === module) main().catch(() => { process.stdout.write('{"status":502,"html":"","error":"browser_failed"}'); process.exitCode = 1; });
