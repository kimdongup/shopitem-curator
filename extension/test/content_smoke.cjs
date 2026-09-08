// Real Chrome DOM smoke test with a mocked extension bridge, never Target.
// Usage: node extension/test/content_smoke.cjs
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const assert = require('node:assert/strict');
const {once} = require('node:events');

async function main() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'curator-chrome-smoke-'));
  const chrome = spawn(process.env.CURATOR_TEST_CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
    '--headless=new', '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-component-update', '--disable-sync',
    '--user-data-dir=' + profile, 'about:blank'], {stdio: ['ignore', 'ignore', 'pipe']});
  let socket;
  try {
    const endpoint = await new Promise((resolve, reject) => {
      let output = '';
      const timeout = setTimeout(() => reject(new Error('Chrome CDP startup timed out')), 20000);
      chrome.on('error', reject);
      chrome.stderr.on('data', data => {
        output += data;
        const match = /DevTools listening on (ws:\/\/[^\s]+)/.exec(output);
        if (match) { clearTimeout(timeout); resolve(match[1]); }
      });
    });
    const origin = new URL(endpoint); origin.protocol = 'http:';
    const targets = await (await fetch(origin.origin + '/json/list')).json();
    socket = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
    await once(socket, 'open');
    let sequence = 0;
    const waiting = new Map();
    socket.addEventListener('message', event => {
      const packet = JSON.parse(event.data), pending = waiting.get(packet.id);
      if (pending) { waiting.delete(packet.id); packet.error ? pending.reject(packet.error) : pending.resolve(packet.result); }
    });
    function cdp(method, params = {}) {
      return new Promise((resolve, reject) => {
        const id = ++sequence; waiting.set(id, {resolve, reject});
        socket.send(JSON.stringify({id, method, params}));
      });
    }
    async function evaluate(expression) {
      const response = await cdp('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true});
      if (response.exceptionDetails) throw new Error(JSON.stringify(response.exceptionDetails));
      return response.result.value;
    }
    async function until(expression) {
      for (let i = 0; i < 80; i++) {
        if (await evaluate(expression)) return;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      const diagnostic = await evaluate('({html:window.testRoot?.innerHTML.slice(-1800),events:window.testEvents})');
      throw new Error('DOM condition timed out: ' + expression + '\n' + JSON.stringify(diagnostic));
    }
    async function mouse(type, x, y) {
      return cdp('Input.dispatchMouseEvent', {type, x, y, button: type === 'mouseMoved' ? 'none' : 'left',
        buttons: type === 'mouseReleased' ? 0 : 1, clickCount: type === 'mouseMoved' ? 0 : 1});
    }
    async function click(text) {
      const position = await evaluate(`(() => {const b=[...window.testRoot.querySelectorAll('button')].find(b=>b.textContent.includes(${JSON.stringify(text)})); if(!b||b.disabled)throw new Error('Missing/enabled button');const r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
      assert.ok(position.x >= 0 && position.x < 1280 && position.y >= 0 && position.y < 900,
        'Button outside viewport: ' + JSON.stringify(position));
      await mouse('mousePressed', position.x, position.y); await mouse('mouseReleased', position.x, position.y);
    }
    await cdp('Emulation.setDeviceMetricsOverride', {width: 1280, height: 900, deviceScaleFactor: 1, mobile: false});
    await cdp('Page.navigate', {url: 'data:text/html,<html lang="ko"><body style="background:%23eef4f6;font-family:system-ui"><h1>Local product fixture</h1><p>Not Target. No live requests.</p></body></html>'});
    await until('document.readyState === "complete"');
    await evaluate(`(() => {
      const attach = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function(options) { const root=attach.call(this,options); window.testRoot=root; return root; };
      window.writes=[];
      const project={id:'project',revision:0,source_image_path:'assets/images/weekend-list.png',entries:[
        {id:'item_0',query:'big notebook',status:'pending'}, {id:'item_1',query:'crayon',status:'pending'}]};
      window.chrome={storage:{local:{get:async()=>({}),set:async()=>{}}},runtime:{onMessage:{addListener:()=>{}},sendMessage:async m=>{
        if(m.kind==='capture'){const canvas=document.createElement('canvas');canvas.width=1280;canvas.height=900;const c=canvas.getContext('2d');c.fillStyle='white';c.fillRect(0,0,1280,900);c.fillStyle='#189b88';c.fillRect(200,180,200,300);return {ok:true,dataUrl:canvas.toDataURL('image/png'),captureId:'capture'};}
        if(m.kind==='select'){window.writes.push(m);project.revision++;project.entries[0].status='selected';}
        return {ok:true,project:structuredClone(project),itemId:'item_0'};
      }}};
    })()`);
    await evaluate(fs.readFileSync(path.join(__dirname, '..', 'content.js'), 'utf8'));
    await until('!!window.testRoot?.querySelector(".bubble")');
    await until('window.testRoot.querySelector(".bubble").textContent.includes("0/2")');
    await evaluate(`window.testEvents=[];for(const type of ['pointerdown','pointermove','pointerup','click'])window.testRoot.addEventListener(type,e=>window.testEvents.push({type,trusted:e.isTrusted,tag:e.target.tagName}),true);`);
    await click('Curator');
    await until('!!window.testRoot.querySelector("select")');
    await click('상품 이미지 선택');
    await until('!!window.testRoot.querySelector("dialog[open]")');
    await mouse('mousePressed', 180, 160); await mouse('mouseMoved', 420, 500); await mouse('mouseReleased', 420, 500);
    await until('!!window.testRoot.querySelector(".preview")');
    const crop = await evaluate(`(() => {const i=window.testRoot.querySelector('.preview');return {width:i.naturalWidth,height:i.naturalHeight};})()`);
    assert.deepEqual(crop, {width: 240, height: 340});
    const artifacts = path.resolve('build/browser-smoke'); fs.mkdirSync(artifacts, {recursive: true});
    const screenshot = await cdp('Page.captureScreenshot', {format: 'png'});
    fs.writeFileSync(path.join(artifacts, 'capture-preview.png'), Buffer.from(screenshot.data, 'base64'));
    await click('담기만');
    await until('window.writes.length === 1 && !window.testRoot.querySelector("dialog")');
    assert.equal(await evaluate('window.writes[0].name'), 'big notebook');
    assert.equal(await evaluate('window.writes[0].price'), 0);
    await click('접기');
    await until('!!window.testRoot.querySelector(".bubble") && !window.testRoot.querySelector(".bubble").disabled');
    const start = await evaluate(`(() => {const r=window.testRoot.querySelector('.bubble').getBoundingClientRect();return {x:r.x+32,y:r.y+32};})()`);
    await mouse('mousePressed', start.x, start.y);
    for (let step = 1; step <= 10; step++) {
      await mouse('mouseMoved', start.x + (50 - start.x) * step / 10, start.y + (220 - start.y) * step / 10);
      await new Promise(resolve => setTimeout(resolve, 16));
    }
    await mouse('mouseReleased', 50, 220);
    assert.equal(await evaluate('document.getElementById("shopitem-curator-widget").style.left'), '12px',
      JSON.stringify(await evaluate('window.testEvents.slice(-12)')));
    await cdp('Emulation.setDeviceMetricsOverride', {width: 320, height: 700, deviceScaleFactor: 1, mobile: false});
    await click('Curator');
    const bounds = await evaluate(`(() => {const r=window.testRoot.querySelector('.box').getBoundingClientRect();return {x:r.x,right:r.right};})()`);
    assert.ok(bounds.x >= 0 && bounds.right <= 320, JSON.stringify(bounds));
    console.log('PASS: real Chrome DOM — crop/preview/save, edge drag, 320px layout (bridge mocked).');
    // Verify storyboard text stays inside the SVG viewBox as well.
    await cdp('Emulation.setDeviceMetricsOverride', {width: 1024, height: 520, deviceScaleFactor: 1, mobile: false});
    for (const file of fs.readdirSync('docs/storyboard').filter(f => f.endsWith('.svg'))) {
      const svg = fs.readFileSync(path.join('docs/storyboard', file), 'utf8');
      await cdp('Page.navigate', {url: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg)});
      await until('document.documentElement.tagName === "svg"');
      const dimensions = await evaluate(`({width:document.documentElement.viewBox.baseVal.width,height:document.documentElement.viewBox.baseVal.height})`);
      await cdp('Emulation.setDeviceMetricsOverride', {...dimensions, deviceScaleFactor: 1, mobile: false});
      const overflow = await evaluate(`Array.from(document.querySelectorAll('text')).filter(t=>{const b=t.getBBox(),v=document.documentElement.viewBox.baseVal;return b.x<v.x||b.x+b.width>v.x+v.width||b.y<v.y||b.y+b.height>v.y+v.height;}).map(t=>t.textContent)`);
      assert.deepEqual(overflow, [], file);
      const rendered = await cdp('Page.captureScreenshot', {format: 'png'});
      fs.writeFileSync(path.join(artifacts, file.replace('.svg', '.png')), Buffer.from(rendered.data, 'base64'));
    }
    console.log('PASS: all storyboard SVGs render without overflowing text.');
  } finally {
    socket?.close();
    if (chrome.exitCode === null) { const exited = once(chrome, 'exit'); chrome.kill('SIGTERM'); await exited; }
    fs.rmSync(profile, {recursive: true, force: true});
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
