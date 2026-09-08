const test = require('node:test');
const assert = require('node:assert/strict');
const {extractProducts, purchaseUrl, imageUrl} = require('./product_metadata.cjs');
const {render, allowedUrl, publicAddress} = require('./runner.cjs');

const product = {item: {product_description: {title: 'Big notebook'},
  buy_url: '/p/big-notebook/-/A-12345678', enrichment: {images: {primary_image_id: 'GUEST_notebook'}}},
  price: {current_retail: 4.5}};

test('extracts atomic product DTOs, no raw request data or credentials', () => {
  assert.deepEqual(extractProducts({data: {search: {products: [product]}}, cookie: 'SECRET'}), [{
    name: 'Big notebook', target_url: 'https://www.target.com/p/big-notebook/-/A-12345678',
    image_url: 'https://target.scene7.com/is/image/Target/GUEST_notebook', price: 4.5}]);
});
test('rejects sponsored, unrelated/unsafe URL and foreign currency metadata', () => {
  assert.deepEqual(extractProducts({...product, labels: ['Sponsored']}), []);
  assert.deepEqual(extractProducts({...product, item: {...product.item, buy_url: 'https://target.com.evil.test/p/-/A-12345678'}}), []);
  assert.deepEqual(extractProducts({'@type': 'Product', name: 'Notebook', url: product.item.buy_url,
    image: 'https://target.scene7.com/is/image/Target/GUEST_notebook', offers: {price: 50, priceCurrency: 'EUR'}}), []);
  assert.equal(purchaseUrl('https://user:pass@www.target.com/p/-/A-12345678'), null);
  assert.equal(imageUrl('https://127.0.0.1/private.png'), null);
});
test('unknown price remains unknown and duplicate products are bounded', () => {
  assert.equal(extractProducts({...product, price: {current_retail: 'invalid'}})[0].price, 0);
  assert.equal(extractProducts(Array(1000).fill(product)).length, 1);
});
test('network allowlist rejects alternate schemes, credentials, ports, private DNS', () => {
  for (const url of ['http://www.target.com', 'https://user@www.target.com', 'https://www.target.com:8443',
    'https://evil.test', 'file:///etc/passwd']) assert.equal(allowedUrl(url), false);
  for (const address of ['127.0.0.1','10.1.2.3','169.254.169.254','192.168.1.1','::1','fc00::1','::ffff:127.0.0.1']) assert.equal(publicAddress(address), false);
  assert.equal(publicAddress('8.8.8.8'), true);
});
test('rejects private DNS before launching any browser', async () => {
  await assert.rejects(render({url: 'https://www.target.com'}, {
    playwright: {chromium: {launch: () => assert.fail('must not launch')}},
    lookup: async () => [{address: '127.0.0.1'}]}), /invalid_address/);
});

// Real Chromium, but every attempted request is intercepted. No Target or proxy
// traffic and no attachment to a running user profile is needed for this test.
async function fixture(config, deny = false) {
  const {chromium} = require('playwright-core');
  const visited = [], aborted = [];
  const html = `<html><body style="height:2400px"><pre id="env"></pre><script>
    document.getElementById('env').textContent = JSON.stringify({webdriver:String(navigator.webdriver),ua:navigator.userAgent,platform:navigator.platform});
    window.addEventListener('mousemove',()=>document.body.dataset.moved='yes');
    window.addEventListener('scroll',()=>document.body.dataset.scrolled='yes');
    fetch('https://redsky.target.com/fixture.json').catch(()=>{});
    fetch('https://127.0.0.1/private').catch(()=>{});
    </script></body></html>`;
  const result = await render({url: 'https://www.target.com/s?searchTerm=notebook',
    executable: process.env.CURATOR_BROWSER_EXECUTABLE ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    ...config}, {lookup: async () => [{address: '8.8.8.8'}], playwright: {chromium: {
    launch: async options => {
      const browser = await chromium.launch(options);
      return {close: () => browser.close(), newContext: async options => {
        const context = await browser.newContext(options);
        const routeOriginal = context.route.bind(context);
        context.route = (pattern, handler) => routeOriginal(pattern, route => handler({
          request: () => route.request(), abort: () => {aborted.push(route.request().url()); return route.abort();},
          continue: () => {
            const url = route.request().url(); visited.push(url);
            if (url.includes('fixture.json')) return route.fulfill({status: deny ? 403 : 200,
              contentType: 'application/json', body: JSON.stringify({data: {products: [product]}})});
            return route.fulfill({status: 200, contentType: 'text/html', body: html});
          }}));
        return context;
      }};
    }}}});
  return {result, visited, aborted};
}
const integration = {skip: process.env.CURATOR_TEST_BROWSER !== '1', timeout: 30000};
test('real isolated browser applies selected flags and observes JSON without replay', integration, async () => {
  const {result, visited, aborted} = await fixture({stealth: true, interaction: true, observe_json: true,
    rotate_headers: true, headers: {'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.7977.83 Safari/537.36'}});
  assert.equal(result.status, 200); assert.equal(result.observed_count, 1);
  assert.match(result.html, /"webdriver":"undefined"/);
  assert.match(result.html, /"platform":"Win32"/);
  assert.match(result.html, /data-moved="yes"/);
  assert.match(result.html, /data-scrolled="yes"/);
  assert.match(result.html, /curator-observed-products/);
  assert.equal(visited.filter(u=>u.includes('fixture.json')).length, 1);
  assert(aborted.includes('https://127.0.0.1/private'));
});
test('real browser returns denied XHR host without exposing response body', integration, async () => {
  const {result} = await fixture({observe_json: true}, true);
  assert.equal(result.status, 403); assert.equal(result.denied_host, 'redsky.target.com');
  assert.equal(result.html, ''); assert.equal(result.observed_count, 0);
});
