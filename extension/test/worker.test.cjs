const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function harness() {
  const storage = {}, calls = [];
  let listener;
  const project = {id: 'project', revision: 0, source_image_path: 'assets/images/list.png', entries: [
    {id: 'item_0', query: 'big notebook', status: 'pending'},
    {id: 'item_1', query: 'bicycle', status: 'pending'},
  ]};
  const tab = {id: 4, windowId: 1, url: 'https://www.target.com/p/notebook/-/A-12345678'};
  const context = vm.createContext({URL, crypto, AbortSignal, setTimeout, clearTimeout,
    chrome: {
      runtime: {id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', getURL: p => 'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' + p,
        onMessage: {addListener: fn => { listener = fn; }}},
      storage: {session: {setAccessLevel: async () => {},
        get: async key => ({[key]: storage[key]}), set: async data => Object.assign(storage, structuredClone(data)),
        remove: async keys => { for (const key of Array.isArray(keys) ? keys : [keys]) delete storage[key]; }}},
      tabs: {query: async () => [structuredClone(tab)],
        sendMessage: async () => {},
        update: async (id, props) => {
          if (storage.failNavigation) throw new Error('Tab closed');
          calls.push({navigation: props.url});
        },
        captureVisibleTab: async () => 'data:image/png;base64,FULL_LOCAL_SCREENSHOT'},
    },
    fetch: async (url, options) => {
      const body = JSON.parse(options.body); calls.push({url, body, headers: options.headers});
      if (url.endsWith('/pair')) return {ok: true, json: async () => ({token: 'SECRET', project: structuredClone(project)})};
      if (url.endsWith('/select')) {
        if (storage.failSave) return {ok: false, status: 409};
        project.revision++;
        project.entries.find(e => e.id === body.item_id).status = body.action === 'skip' ? 'skipped' : 'selected';
      }
      return {ok: true, json: async () => structuredClone(project)};
    },
  });
  context.importScripts = name => vm.runInContext(fs.readFileSync(path.join(__dirname, '..', name), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'background.js'), 'utf8'), context);
  const popup = {id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', url: 'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/popup.html'};
  const target = {id: popup.id, frameId: 0, tab: {id: 4}, url: tab.url};
  const request = (message, sender = target) => {
    context.packet = message; context.sender = sender;
    return vm.runInContext('handle(packet, sender)', context);
  };
  const pair = () => request({kind: 'pair', code: 'b'.repeat(32)}, popup);
  return {context, request, pair, calls, storage, tab, target, popup, listener};
}

test('Target URL and search navigation validation', () => {
  const {context} = harness();
  const p = context.CuratorProtocol;
  for (const url of ['javascript:alert(1)', 'https://target.com.evil.test/p/-/A-123',
    'https://target.com@evil.test/p/-/A-123', 'http://target.com/p/-/A-123',
    'https://target.com:8443/p/-/A-123', 'https://www.target.com/s?searchTerm=x']) {
    assert.equal(p.targetUrl(url, true), null);
  }
  assert.ok(p.targetUrl('https://www.target.com/p/item/-/A-123', true));
  assert.equal(p.searchUrl('bike & helmet'), 'https://www.target.com/s?searchTerm=bike%20%26%20helmet');
  assert.match(p.operationId(), /^[a-f0-9]{32}$/);
});

test('pairing is popup-only; summaries never disclose project capability', async () => {
  const h = harness();
  await assert.rejects(h.request({kind: 'pair', code: 'b'.repeat(32)}));
  const result = await h.pair();
  assert.equal(JSON.stringify(result).includes('SECRET'), false);
  assert.equal(h.storage.connection.token, 'SECRET');
  assert.equal(JSON.stringify(await h.request({kind: 'state'})).includes('SECRET'), false);
  await assert.rejects(h.request({kind: 'state'}, {...h.target, frameId: 1}));
  await assert.rejects(h.request({kind: 'state'}, {...h.target, tab: {id: 9}}));
  await assert.rejects(h.request({kind: 'state'}, {...h.target, url: 'https://evil.test'}));
});

test('only acknowledged cropped image selection advances search', async () => {
  const h = harness(); await h.pair();
  const capture = await h.request({kind: 'capture'});
  const message = {kind: 'select', captureId: capture.captureId, imageBase64: 'CROPPED_IMAGE',
    name: 'Notebook', price: 0, next: true, targetUrl: 'https://evil.test'};
  h.storage.failSave = true;
  await assert.rejects(h.request(message));
  assert.equal(h.calls.some(c => c.navigation), false);
  h.storage.failSave = false;
  await h.request(message);
  const writes = h.calls.filter(c => c.url?.endsWith('/select'));
  assert.equal(writes.at(-1).body.target_url, h.tab.url);
  assert.equal(writes.at(-1).body.image_base64, 'CROPPED_IMAGE');
  assert.equal(writes[0].body.operation_id, writes[1].body.operation_id);
  assert.equal(h.calls.at(-1).navigation, 'https://www.target.com/s?searchTerm=bicycle');
  assert.equal(JSON.stringify(writes).includes('FULL_LOCAL_SCREENSHOT'), false);
  assert.equal(h.storage.capture, undefined);
});

test('changed tab/PDP or item invalidates screenshot receipt', async () => {
  const h = harness(); await h.pair();
  h.tab.url = 'https://www.target.com/s?searchTerm=notebook';
  await assert.rejects(h.request({kind: 'capture'}));
  h.tab.url = 'https://www.target.com/p/notebook/-/A-12345678';
  const receipt = await h.request({kind: 'capture'});
  h.tab.url = 'https://www.target.com/p/other/-/A-99999999';
  await assert.rejects(h.request({kind: 'select', captureId: receipt.captureId, imageBase64: 'CROP', name: 'x', price: 0}));
  assert.equal(h.calls.some(c => c.url?.endsWith('/select')), false);
  await h.request({kind: 'choose', itemId: 'item_1'});
  assert.equal(h.storage.capture, undefined);
});

test('post-save navigation failure remains an acknowledged save; disconnect clears grant', async () => {
  const h = harness(); await h.pair();
  const capture = await h.request({kind: 'capture'});
  h.storage.failNavigation = true;
  const result = await h.request({kind: 'select', captureId: capture.captureId,
    imageBase64: 'CROP', name: 'Notebook', price: 0, next: true});
  assert.match(result.warning, /저장되었습니다/);
  assert.equal(result.project.revision, 1);
  await h.request({kind: 'disconnect'}, h.popup);
  assert.ok(h.calls.some(c => c.url?.endsWith('/disconnect')));
  assert.equal(h.storage.connection, undefined);
});

test('manifest stays Target-only without cookies, side panel or all-URLs capture permission', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'manifest.json')));
  assert.deepEqual(manifest.permissions, ['activeTab', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['http://127.0.0.1/*']);
  assert.equal(manifest.side_panel, undefined);
  assert.equal(manifest.content_scripts[0].all_frames, false);
  assert.ok(manifest.content_scripts[0].matches.every(m => /^https:\/\/(www\.)?target\.com\/\*$/.test(m)));
});
