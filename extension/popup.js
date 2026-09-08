const status = document.querySelector('#status');
for (const kind of ['pair', 'bind', 'disconnect']) {
  document.getElementById(kind).addEventListener('click', async () => {
    const buttons = [...document.querySelectorAll('button')];
    buttons.forEach(button => { button.disabled = true; });
    try {
      const result = await chrome.runtime.sendMessage({kind, code: document.querySelector('#code').value.trim()});
      if (!result.ok) throw new Error(result.error);
      document.querySelector('#code').value = '';
      status.textContent = kind === 'disconnect' ? '이 브라우저의 연결 정보를 지웠습니다.'
        : '연결되었습니다. 팝업을 닫고 페이지의 Curator 버튼을 누르세요. 버튼이 없으면 Target 탭을 새로고침하세요.';
    } catch (error) { status.textContent = error.message; }
    finally { buttons.forEach(button => { button.disabled = false; }); }
  });
}
