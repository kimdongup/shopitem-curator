const status = document.querySelector('#status');
void chrome.storage.local.get('backendOrigin').then(({backendOrigin}) => {
  if (backendOrigin && !document.querySelector('#server').matches(':focus')) document.querySelector('#server').value = backendOrigin;
});
for (const kind of ['pair', 'bind', 'disconnect']) {
  document.getElementById(kind).addEventListener('click', async () => {
    const buttons = [...document.querySelectorAll('button')];
    buttons.forEach(button => { button.disabled = true; });
    try {
      // Bind/disconnect use the previously paired host, even if this field was edited.
      const backendOrigin = kind === 'pair'
        ? CuratorProtocol.backendOrigin(document.querySelector('#server').value) : undefined;
      // Request only this host, in direct response to the user's button click.
      if (kind === 'pair' && backendOrigin.startsWith('https:') &&
          !await chrome.permissions.request({origins: [backendOrigin + '/*']})) throw new Error('서버 연결 권한을 허용해야 연결할 수 있습니다.');
      const result = await chrome.runtime.sendMessage({kind, backendOrigin, code: document.querySelector('#code').value.trim()});
      if (!result.ok) throw new Error(result.error);
      if (kind === 'pair') await chrome.storage.local.set({backendOrigin});
      document.querySelector('#code').value = '';
      status.textContent = kind === 'disconnect' ? '이 브라우저의 연결 정보를 지웠습니다.'
        : '연결되었습니다. 팝업을 닫고 페이지의 Curator 버튼을 누르세요. 버튼이 없으면 Target 탭을 새로고침하세요.';
    } catch (error) { status.textContent = error.message; }
    finally { buttons.forEach(button => { button.disabled = false; }); }
  });
}
