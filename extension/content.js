(() => {
  'use strict';
  if (window.top !== window || document.getElementById('shopitem-curator-widget')) return;
  const host = document.createElement('div');
  host.id = 'shopitem-curator-widget';
  host.style.cssText = 'all:initial;position:fixed!important;display:block!important;z-index:2147483647!important;right:12px!important;top:60%!important;';
  const root = host.attachShadow({mode: 'closed'});
  const style = document.createElement('style');
  style.textContent = `
    :host{color-scheme:dark}*{box-sizing:border-box}button,input,select{font:inherit}
    .box{font:14px/1.5 system-ui,sans-serif;color:#f2f7fa;width:min(330px,calc(100vw - 24px));background:#142331;border:1px solid #4c6578;border-radius:18px;box-shadow:0 12px 40px #0006;padding:14px}
    .bubble{width:64px;height:64px;border-radius:50%;border:2px solid #b9fff1;background:#076f6a;color:white;font:bold 13px/1.2 system-ui;box-shadow:0 6px 18px #0005;touch-action:none;cursor:grab}
    .bar{display:flex;justify-content:space-between;align-items:center;gap:8px;cursor:grab;touch-action:none}
    .bar strong{font-size:17px}.bar button{width:auto;margin:0;padding:4px 10px}
    button{cursor:pointer;border:1px solid #547185;border-radius:10px;background:#253c4d;color:inherit;padding:10px;margin:6px 0;width:100%}button:disabled{opacity:.5;cursor:wait}
    button.primary{background:#08786f;border-color:#56d6bf}button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid #7df6da}
    p{margin:8px 0;overflow-wrap:anywhere}small{color:#b3c7d4}label{display:block;margin-top:8px}input,select{width:100%;background:#0e1923;color:#f2f7fa;border:1px solid #587080;border-radius:8px;padding:8px}
    .status{color:#a6eedb;max-height:90px;overflow:auto}.row{display:flex;gap:8px}.row>*{flex:1}.list{max-height:35vh;overflow:auto}
    dialog{border:0;padding:0;background:transparent;color:#f2f7fa;width:100vw;height:100vh;max-width:none;max-height:none;margin:0;overflow:hidden;font:14px/1.5 system-ui}
    dialog::backdrop{background:#08111ce6}.shot{position:absolute;inset:0;width:100%;height:100%;user-select:none;pointer-events:none}
    .surface{position:absolute;inset:0;cursor:crosshair;touch-action:none}.selection{position:absolute;border:3px solid #00dcb2;background:#00dcb21f;pointer-events:none}
    .hint{position:absolute;top:12px;left:50%;transform:translateX(-50%);width:min(540px,90vw);padding:10px 16px;border-radius:12px;background:#142331ef;text-align:center;pointer-events:none}
    .cancel{position:absolute;bottom:16px;right:16px;width:auto;background:#142331}.form{position:absolute;inset:0;display:grid;place-items:center;background:#08111ce6}
    .form .box{max-height:94vh;overflow:auto}.preview{display:block;max-height:180px;max-width:100%;margin:auto;background:white;border-radius:10px}
  `;
  root.append(style);
  document.documentElement.append(host);
  let snapshot = null, expanded = false, busy = false, message = '툴바의 Curator 아이콘에서 연결하세요.';
  let dock = 'right', y = innerHeight * .6, timer, modal = null, moved = false, dragging = false;

  function el(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function button(text, action, className) {
    const node = el('button', text, className); node.type = 'button'; node.disabled = busy;
    node.addEventListener('click', event => { if (event.isTrusted && !moved) void run(action); });
    return node;
  }
  async function rpc(body) {
    const response = await chrome.runtime.sendMessage(body);
    if (!response?.ok) throw new Error(response?.error ?? '확장 프로그램 연결을 확인하세요.');
    return response;
  }
  function place() {
    const height = host.getBoundingClientRect().height;
    y = Math.max(12, Math.min(y, innerHeight - height - 12));
    host.style.setProperty('top', y + 'px', 'important');
    host.style.setProperty('left', dock === 'left' ? '12px' : 'auto', 'important');
    host.style.setProperty('right', dock === 'right' ? '12px' : 'auto', 'important');
  }
  function draggable(node) {
    node.addEventListener('pointerdown', event => {
      if (!event.isTrusted || (event.target !== node && event.target.tagName === 'BUTTON')) return;
      moved = false;
      dragging = true;
      const start = {x: event.clientX, y: event.clientY, top: y};
      const pointerId = event.pointerId;
      const move = e => {
        if (e.pointerId !== pointerId) return;
        if (Math.hypot(e.clientX - start.x, e.clientY - start.y) > 5) moved = true;
        if (!moved) return;
        y = start.top + e.clientY - start.y;
        dock = e.clientX < innerWidth / 2 ? 'left' : 'right'; place();
      };
      const up = e => {
        if (e.pointerId !== pointerId) return;
        dragging = false;
        window.removeEventListener('pointermove', move, true);
        window.removeEventListener('pointerup', up, true);
        window.removeEventListener('pointercancel', up, true);
        void chrome.storage.local.set({widgetPosition: {dock, ratio: y / innerHeight}});
        setTimeout(() => { moved = false; }, 0);
      };
      window.addEventListener('pointermove', move, true);
      window.addEventListener('pointerup', up, true);
      window.addEventListener('pointercancel', up, true);
    });
  }
  function render() {
    if (dragging) return;
    root.querySelector('.widget')?.remove();
    const project = snapshot?.project;
    const count = project?.entries.filter(e => e.status === 'selected').length ?? 0;
    if (!expanded) {
      const bubble = button(`Curator\n${count}/${project?.entries.length ?? '–'}`, async () => {
        expanded = true; render();
      }, 'bubble widget');
      bubble.style.whiteSpace = 'pre-line';
      bubble.setAttribute('aria-label', 'Curator 열기. 드래그하여 가장자리로 이동');
      draggable(bubble); root.append(bubble); place(); return;
    }
    const box = el('section', undefined, 'box widget');
    const bar = el('div', undefined, 'bar');
    bar.append(el('strong', 'Curator에 담기'), button('접기', async () => { expanded = false; render(); }));
    draggable(bar); box.append(bar);
    if (project) {
      box.append(el('p', project.source_image_path.split('/').pop()),
        el('small', `담음 ${count} / 전체 ${project.entries.length} · 목록에서 품목을 다시 선택할 수 있어요.`));
      const select = el('select'); select.setAttribute('aria-label', '쇼핑 목록 항목'); select.disabled = busy;
      for (const entry of project.entries) {
        const option = el('option', `${entry.status === 'selected' ? '✓ ' : entry.status === 'skipped' ? '↷ ' : ''}${entry.query}`);
        option.value = entry.id; select.append(option);
      }
      select.value = snapshot.itemId;
      select.addEventListener('change', event => { if (event.isTrusted) void run(async () => {
        snapshot = await rpc({kind: 'choose', itemId: select.value}); message = '선택한 품목을 Target에서 검색하세요.';
      }); });
      box.append(select, button('이 품목 Target 검색', async () => { await rpc({kind: 'search'}); }));
      box.append(button('상품 이미지 선택 → 담기', capture, 'primary'));
      box.append(button('건너뛰고 다음 검색', async () => {
        snapshot = await rpc({kind: 'skip', next: true}); message = snapshot.warning ?? '건너뛰었습니다. 목록에서 다시 선택할 수 있어요.';
      }));
    } else box.append(el('p', '앱의 2단계에서 연결 코드를 만들고, 이 Target 탭의 툴바에서 Curator 아이콘을 누르세요.'));
    const status = el('p', message, 'status'); status.setAttribute('role', 'status');
    box.append(status, button('목록 새로고침', refresh), el('small', '이동은 위 제목을 드래그하세요. 담기는 상품 상세 페이지에서만 가능합니다.'));
    root.append(box); place();
  }
  async function run(action) {
    if (busy) return;
    busy = true; render();
    try { await action(); }
    catch (error) { message = error.message; }
    finally { busy = false; render(); }
  }
  async function refresh() { snapshot = await rpc({kind: 'state'}); message = '목록이 연결되었습니다. 검색하고 마음에 드는 상품을 열어 주세요.'; }
  function closeModal() { modal?.close(); modal?.remove(); modal = null; }

  async function capture() {
    const entry = snapshot?.project.entries.find(e => e.id === snapshot.itemId);
    if (!entry) return;
    host.style.setProperty('visibility', 'hidden', 'important');
    let result;
    try {
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      result = await rpc({kind: 'capture'});
    } finally { host.style.removeProperty('visibility'); }
    const image = new Image(); image.src = result.dataUrl; await image.decode();
    const dialog = el('dialog'); modal = dialog;
    const shot = el('img', undefined, 'shot'); shot.src = result.dataUrl; shot.alt = '현재 상품 페이지 캡처 — 상품 이미지 부분만 드래그하세요.';
    const surface = el('div', undefined, 'surface');
    const selection = el('div', undefined, 'selection'); selection.hidden = true;
    surface.append(selection);
    dialog.append(shot, surface, el('div', '상품 이미지 영역만 드래그하세요. 전체 화면은 서버에 저장되지 않습니다. Esc: 취소', 'hint'));
    const cancel = el('button', '취소', 'cancel'); cancel.addEventListener('click', closeModal); dialog.append(cancel);
    dialog.addEventListener('cancel', () => { closeModal(); });
    root.append(dialog); dialog.showModal();
    let start = null;
    function point(event) { return {x: Math.max(0, Math.min(innerWidth, event.clientX)), y: Math.max(0, Math.min(innerHeight, event.clientY))}; }
    surface.addEventListener('pointerdown', event => {
      if (!event.isTrusted) return;
      start = point(event); surface.setPointerCapture(event.pointerId); selection.hidden = false;
      selection.style.cssText = `left:${start.x}px;top:${start.y}px;width:0;height:0`;
    });
    surface.addEventListener('pointermove', event => {
      if (!start) return;
      const end = point(event);
      selection.style.cssText = `left:${Math.min(start.x,end.x)}px;top:${Math.min(start.y,end.y)}px;width:${Math.abs(end.x-start.x)}px;height:${Math.abs(end.y-start.y)}px`;
    });
    surface.addEventListener('pointerup', event => {
      if (!start || !event.isTrusted) return;
      const end = point(event), left = Math.min(start.x, end.x), top = Math.min(start.y, end.y);
      const width = Math.abs(end.x - start.x), height = Math.abs(end.y - start.y); start = null;
      if (width < 24 || height < 24) { selection.hidden = true; return; }
      const scaleX = image.naturalWidth / innerWidth, scaleY = image.naturalHeight / innerHeight;
      const sourceWidth = width * scaleX, sourceHeight = height * scaleY;
      const scale = Math.min(1, 1000 / Math.max(sourceWidth, sourceHeight));
      const canvas = el('canvas'); canvas.width = Math.max(1, Math.round(sourceWidth * scale)); canvas.height = Math.max(1, Math.round(sourceHeight * scale));
      canvas.getContext('2d').drawImage(image, left * scaleX, top * scaleY, sourceWidth, sourceHeight, 0, 0, canvas.width, canvas.height);
      const cropped = canvas.toDataURL('image/png');
      // Full screenshot remains local, and is released with the capture dialog.
      const form = el('div', undefined, 'form'), box = el('div', undefined, 'box');
      const preview = el('img', undefined, 'preview'); preview.src = cropped; preview.alt = '저장할 상품 이미지';
      const nameLabel = el('label', '상품 이름 (수정 가능)'), name = el('input'); name.value = entry.query; name.maxLength = 300; nameLabel.append(name);
      const priceLabel = el('label', '가격 USD (선택, 모르면 비워 두세요)'), price = el('input'); price.type = 'number'; price.min = '0'; price.max = '100000'; price.step = '.01'; priceLabel.append(price);
      const note = el('p', '이 이미지 영역과 현재 상품 URL만 앱에 저장합니다.'); note.setAttribute('role', 'status');
      box.append(el('strong', '이 상품을 Curator에 담을까요?'), preview, nameLabel, priceLabel, note);
      let saving = false;
      function saveButton(text, next) {
        const btn = el('button', text, 'primary');
        btn.addEventListener('click', async event => {
          if (!event.isTrusted || saving) return;
          if (!name.value.trim() || !price.checkValidity()) { note.textContent = '이름과 가격을 확인해 주세요.'; return; }
          saving = true; box.querySelectorAll('button').forEach(b => { b.disabled = true; });
          try {
            snapshot = await rpc({kind: 'select', captureId: result.captureId,
              imageBase64: cropped.split(',')[1], name: name.value.trim(), price: price.value === '' ? 0 : Number(price.value), next});
            closeModal(); message = snapshot.warning ?? '저장되었습니다. 앱에서 선택 결과 적용을 누르세요.'; render();
          } catch (error) { note.textContent = error.message; }
          finally { saving = false; box.querySelectorAll('button').forEach(b => { b.disabled = false; }); }
        }); return btn;
      }
      const retry = el('button', '영역 다시 선택'); retry.addEventListener('click', () => { form.remove(); selection.hidden = true; });
      box.append(saveButton('담고 다음 검색', true), saveButton('담기만', false), retry);
      form.append(box); dialog.append(form); name.focus();
    });
  }
  async function poll() {
    if (!document.hidden && !busy && !modal) {
      try {
        const next = await rpc({kind: 'state'});
        const changed = next.project?.id !== snapshot?.project?.id ||
          next.project?.revision !== snapshot?.project?.revision || next.itemId !== snapshot?.itemId;
        snapshot = next;
        if (changed) render();
      }
      catch (error) { message = error.message; render(); }
    }
    timer = setTimeout(poll, 8000);
  }
  window.addEventListener('resize', () => { closeModal(); place(); });
  window.addEventListener('pagehide', () => { clearTimeout(timer); closeModal(); });
  chrome.runtime.onMessage.addListener(message => {
    if (message.kind === 'connected') { expanded = true; void run(refresh); }
  });
  void chrome.storage.local.get('widgetPosition').then(({widgetPosition: position}) => {
    if (position && ['left', 'right'].includes(position.dock) && Number.isFinite(position.ratio)) {
      dock = position.dock; y = position.ratio * innerHeight;
    }
    render(); void poll();
  });
})();
