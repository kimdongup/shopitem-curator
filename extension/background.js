importScripts('protocol.js');
const P = CuratorProtocol;
const POPUP = chrome.runtime.getURL('popup.html');
// Content scripts never receive the capability, pairing code or full auth state.
void chrome.storage.session.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
let busy = false;

async function api(path, body, token, backendOrigin) {
  const base = P.backendOrigin(backendOrigin);
  const response = await fetch(base + '/v1/browser-bridge/' + path, {
    method: 'POST', credentials: 'omit', redirect: 'error', cache: 'no-store',
    headers: {'Content-Type': 'application/json', 'X-Curator-Extension-Id': chrome.runtime.id,
      ...(token ? {Authorization: 'Bearer ' + token} : {})},
    body: JSON.stringify(body), signal: AbortSignal.timeout(60000),
  });
  if (!response.ok) {
    const messages = {401: '연결이 만료되었습니다. 앱에서 새 코드를 발급받아 연결하세요.',
      403: '서버 주소와 확장 프로그램 연결 설정을 확인하세요.',
      404: '문서 또는 연결 기능을 찾지 못했습니다. 최신 백엔드를 실행하세요.',
      409: '선택 내용이 바뀌었습니다. 목록을 새로고침한 뒤 다시 담으세요.',
      413: '이미지 영역이 큽니다. 더 작게 잘라 주세요.',
      429: '요청이 많습니다. 잠시 후 다시 시도하세요.'};
    throw new Error(messages[response.status] ?? '저장하지 못했습니다. 상품 페이지와 이미지 영역을 확인하세요.');
  }
  return response.json();
}
async function connection() {
  const {connection: c} = await chrome.storage.session.get('connection');
  if (!c) throw new Error('Target 탭에서 툴바의 Curator 확장 아이콘을 눌러 먼저 연결하세요.');
  return c;
}
async function activeTargetTab() {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  if (!tab || !P.targetUrl(tab.url)) throw new Error('일반 Chrome 창에서 Target 페이지를 먼저 여세요.');
  return tab;
}
async function refresh(c) {
  const project = await api('read', {}, c.token, c.backendOrigin);
  const latest = await connection();
  if (latest.token !== c.token || latest.tabId !== c.tabId) throw new Error('연결이 변경되었습니다.');
  const item = project.entries.find(e => e.id === c.itemId) ?? P.nextPending(project);
  const next = {...latest, project, itemId: item?.id ?? project.entries[0]?.id};
  await chrome.storage.session.set({connection: next});
  return next;
}
function summary(c) { return {project: c.project, itemId: c.itemId}; }
async function sendToTab(tabId) {
  try { await chrome.tabs.sendMessage(tabId, {kind: 'connected'}); }
  catch { /* Tab opened before extension installation: user reloads Target. */ }
}
async function handle(message, sender) {
  const popup = sender.url === POPUP && !sender.tab;
  const target = sender.frameId === 0 && sender.tab && P.targetUrl(sender.url);
  if (sender.id !== chrome.runtime.id || (!popup && !target)) throw new Error('허용되지 않은 요청입니다.');
  if (popup) {
    if (message.kind === 'disconnect') {
      const {connection: existing} = await chrome.storage.session.get('connection');
      if (existing) {
        try { await api('disconnect', {}, existing.token, existing.backendOrigin); }
        catch { /* Offline logout still removes the local capability. */ }
      }
      await chrome.storage.session.remove(['connection', 'capture']);
      return {};
    }
    if (message.kind === 'pair') {
      if (!/^[a-f0-9]{32}$/.test(message.code)) throw new Error('앱의 32자리 연결 코드를 입력하세요.');
      const backendOrigin = P.backendOrigin(message.backendOrigin);
      if (backendOrigin.startsWith('https:') &&
          !await chrome.permissions.contains({origins: [backendOrigin + '/*']})) {
        throw new Error('이 Render 서버에 대한 연결 권한을 허용하세요.');
      }
      const tab = await activeTargetTab();
      const result = await api('pair', {code: message.code}, undefined, backendOrigin);
      const item = P.nextPending(result.project) ?? result.project.entries[0];
      const c = {token: result.token, backendOrigin, project: result.project, tabId: tab.id, itemId: item?.id};
      await chrome.storage.session.set({connection: c});
      await chrome.storage.session.remove('capture');
      await sendToTab(tab.id);
      return summary(c);
    }
    if (message.kind === 'bind') {
      const tab = await activeTargetTab();
      const c = await connection();
      const bound = {...c, tabId: tab.id};
      await chrome.storage.session.set({connection: bound});
      await chrome.storage.session.remove('capture');
      await sendToTab(tab.id);
      return summary(await refresh(bound));
    }
    throw new Error('알 수 없는 연결 요청입니다.');
  }
  let c = await connection();
  if (sender.tab.id !== c.tabId) throw new Error('이 탭의 툴바에서 Curator를 누르고 ‘이 탭 사용’을 선택하세요.');
  if (message.kind === 'state') return summary(await refresh(c));
  if (message.kind === 'choose') {
    if (!c.project.entries.some(e => e.id === message.itemId)) throw new Error('목록 항목을 선택하세요.');
    c = {...c, itemId: message.itemId};
    await chrome.storage.session.set({connection: c});
    await chrome.storage.session.remove('capture');
    return summary(c);
  }
  const entry = c.project.entries.find(e => e.id === c.itemId);
  if (!entry) throw new Error('먼저 목록 항목을 선택하세요.');
  if (message.kind === 'search') {
    await chrome.tabs.update(c.tabId, {url: P.searchUrl(entry.query)});
    return {};
  }
  if (message.kind === 'capture') {
    const tab = await activeTargetTab();
    if (tab.id !== c.tabId || !P.targetUrl(tab.url, true)) throw new Error('검색 결과가 아닌 상품 상세 페이지에서 담아 주세요.');
    c = await refresh(c);
    let dataUrl;
    try { dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, {format: 'png'}); }
    catch { throw new Error('이 Target 탭에서 툴바의 Curator 아이콘을 한 번 누른 뒤 다시 담아 주세요.'); }
    const after = await activeTargetTab();
    if (after.id !== tab.id || after.url !== tab.url) throw new Error('캡처 중 탭이 변경되었습니다. 다시 담아 주세요.');
    const receipt = {id: P.operationId(), itemId: c.itemId, projectId: c.project.id,
      revision: c.project.revision, targetUrl: tab.url, expires: Date.now() + 5 * 60 * 1000};
    await chrome.storage.session.set({capture: receipt});
    return {dataUrl, captureId: receipt.id};
  }
  if (message.kind === 'select' || message.kind === 'skip') {
    let body;
    if (message.kind === 'select') {
      const {capture} = await chrome.storage.session.get('capture');
      const tab = await activeTargetTab();
      if (!capture || capture.id !== message.captureId || capture.expires < Date.now() ||
          capture.projectId !== c.project.id || capture.itemId !== c.itemId ||
          tab.id !== c.tabId || tab.url !== capture.targetUrl) throw new Error('화면 또는 목록이 바뀌었습니다. 다시 캡처하세요.');
      if (typeof message.imageBase64 !== 'string' || message.imageBase64.length > 2800000) throw new Error('이미지 영역을 더 작게 선택하세요.');
      body = {action: 'select', item_id: c.itemId, revision: capture.revision,
        operation_id: capture.id, target_url: capture.targetUrl, image_base64: message.imageBase64,
        name: message.name, price: message.price};
    } else {
      body = {action: 'skip', item_id: c.itemId, revision: c.project.revision,
        operation_id: P.operationId()};
    }
    const project = await api('select', body, c.token, c.backendOrigin);
    const nextItem = P.nextPending(project, c.itemId);
    c = {...c, project, itemId: nextItem?.id ?? c.itemId};
    await chrome.storage.session.set({connection: c});
    await chrome.storage.session.remove('capture');
    // Advance only after the server acknowledges the project write.
    if (message.next && nextItem) {
      try { await chrome.tabs.update(c.tabId, {url: P.searchUrl(nextItem.query)}); }
      catch { return {...summary(c), warning: '저장되었습니다. 다음 검색은 위젯의 검색 버튼으로 열어 주세요.'}; }
    }
    return summary(c);
  }
  throw new Error('알 수 없는 위젯 요청입니다.');
}
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (busy) { reply({ok: false, error: '요청을 처리 중입니다. 잠시 후 다시 눌러 주세요.'}); return false; }
  busy = true;
  handle(message ?? {}, sender).then(value => reply({ok: true, ...value}), error => {
    const text = error instanceof TypeError || error.name === 'TimeoutError'
      ? '서버에 연결할 수 없습니다. 앱을 먼저 열어 서버를 깨우고 주소·권한을 확인하세요.' : error.message;
    reply({ok: false, error: text || '요청을 처리하지 못했습니다.'});
  }).finally(() => { busy = false; });
  return true;
});
