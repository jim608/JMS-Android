// Owned loopback acceptance. Importing or --check never starts network/browser.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRemoteControlFixture, fixtureConstants as C, runFixtureUnitChecks } from './remote_control_fixture.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const EVIDENCE = path.resolve(ROOT, '..', 'release-checks', 'remote-control57');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const clone = value => structuredClone(value);

export function argumentsFor(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index++) {
    const key = argv[index];
    assert.ok(['--check', '--go', '--bundle', '--media', '--out', '--chrome', '--expected-main-sha256', '--duration-seconds'].includes(key), 'Unknown argument');
    assert.ok(!Object.hasOwn(args, key), 'Duplicate argument');
    args[key] = ['--check', '--go'].includes(key) ? true : argv[++index];
    assert.notEqual(args[key], undefined, 'Missing argument value');
  }
  return args;
}

export class CDP {
  constructor(socket) {
    this.socket = socket; this.serial = 0; this.pending = new Map(); this.events = []; this.handlers = [];
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const item = this.pending.get(message.id);
        if (!item) return;
        this.pending.delete(message.id); clearTimeout(item.timer);
        message.error ? item.reject(new Error(JSON.stringify(message.error))) : item.resolve(message.result);
      } else {
        if (this.events.length < 10000) this.events.push(message);
        for (const handler of this.handlers) handler(message);
      }
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.serial;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`CDP timeout ${method}`)); }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  async evaluate(sessionId, expression) {
    const result = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (result.exceptionDetails) throw new Error('Browser evaluation failed: ' + result.exceptionDetails.text);
    return result.result.value;
  }
  close() {
    for (const item of this.pending.values()) { clearTimeout(item.timer); item.reject(new Error('CDP closed')); }
    this.pending.clear(); this.socket.close();
  }
}

export function isOwnedConnectAuthority(authority, origin) {
  try {
    const target = new URL(origin);
    return target.protocol === 'http:' && target.hostname === '127.0.0.1' &&
      target.port !== '' && target.origin === origin && authority === target.host;
  } catch { return false; }
}

// No DNS resolution or unrestricted upstream is performed by this proxy.
// Chromium tunnels even plain ws through CONNECT. Only the exact owned
// loopback authority is supported; every other CONNECT remains forbidden.
async function loopbackProxy(origin, audit) {
  const allowed = new URL(origin), sockets = new Set();
  const approved = input => {
    try { const target = new URL(input); return target.protocol === 'http:' && target.origin === origin && !target.username && !target.password; }
    catch { return false; }
  };
  const server = http.createServer((request, response) => {
    if (!approved(request.url)) { audit.denied.push({ method: request.method, kind: 'http' }); response.writeHead(403).end(); return; }
    const target = new URL(request.url);
    const headers = { ...request.headers, host: allowed.host };
    delete headers['proxy-authorization']; delete headers['proxy-connection'];
    const upstream = http.request({ host: '127.0.0.1', port: Number(allowed.port), method: request.method,
      path: target.pathname + target.search, headers }, result => { response.writeHead(result.statusCode, result.headers); result.pipe(response); });
    audit.forwarded++;
    upstream.on('error', () => { if (!response.headersSent) response.writeHead(502); response.end(); });
    request.pipe(upstream);
  });
  server.on('connect', (request, socket, head) => {
    if (!isOwnedConnectAuthority(request.url, origin) || head.length > 65536) {
      audit.denied.push({ kind: 'connect', ownedDestination: request.url === allowed.host });
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
    }
    // Ignore the client's authority when choosing the upstream: it is always
    // this run's captured numeric loopback/port. No arbitrary tunnel or DNS.
    const upstream = net.createConnection({ host: '127.0.0.1', port: Number(allowed.port) });
    sockets.add(upstream); upstream.once('close', () => sockets.delete(upstream));
    const lifetime = setTimeout(() => { upstream.destroy(); socket.destroy(); }, 180000);
    lifetime.unref();
    socket.once('close', () => { clearTimeout(lifetime); upstream.destroy(); });
    upstream.once('close', () => { clearTimeout(lifetime); socket.destroy(); });
    upstream.setTimeout(3000, () => upstream.destroy());
    upstream.on('error', () => socket.destroy()); socket.on('error', () => upstream.destroy());
    upstream.once('connect', () => {
      upstream.setTimeout(0); audit.tunneled++;
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream); upstream.pipe(socket);
    });
  });
  server.on('upgrade', (request, socket, head) => {
    const absolute = request.url.startsWith('/') ? origin + request.url : request.url.replace(/^ws:/, 'http:');
    if (!approved(absolute)) { audit.denied.push({ kind: 'upgrade' }); socket.destroy(); return; }
    const target = new URL(absolute);
    const upstream = net.createConnection({ host: '127.0.0.1', port: Number(allowed.port) });
    sockets.add(upstream); upstream.once('close', () => sockets.delete(upstream));
    upstream.on('error', () => socket.destroy()); socket.on('error', () => upstream.destroy());
    upstream.once('connect', () => {
      const headers = Object.entries(request.headers).filter(([key]) => !key.startsWith('proxy-'))
        .map(([key, value]) => `${key}: ${key === 'host' ? allowed.host : value}`).join('\r\n');
      upstream.write(`${request.method} ${target.pathname}${target.search} HTTP/1.1\r\n${headers}\r\n\r\n`);
      if (head.length) upstream.write(head);
      socket.pipe(upstream); upstream.pipe(socket);
    });
  });
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve); });
  return { port: server.address().port, async close() { for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); } };
}

const deepElements = `function elements(){const roots=[document],all=[];for(let i=0;i<roots.length;i++)for(const e of roots[i].querySelectorAll('*')){all.push(e);if(e.shadowRoot)roots.push(e.shadowRoot);}return all;}`;
const readProbe = `(()=>{const status=document.getElementById('remote-probe-state');if(status?.textContent)return JSON.parse(status.textContent);${deepElements}const e=elements().find(e=>(e.getAttribute('aria-label')||'').startsWith('remote-probe '));return e?JSON.parse(e.getAttribute('aria-label').slice(13)):null;})()`;
const readVideo = `(()=>{${deepElements}const v=elements().find(e=>e.tagName==='VIDEO');if(!v)return null;return{paused:v.paused,time:v.currentTime,duration:v.duration,seeking:v.seeking,ready:v.readyState,tracks:Array.from(v.textTracks).map(t=>({label:t.label,mode:t.mode,cues:Array.from(t.activeCues||[]).map(c=>c.text)}))};})()`;

export async function until(test, description, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await test()) return; await sleep(75); }
  throw new Error('Timed out: ' + description);
}

export function semanticLabelMatches(text, label) {
  return typeof text === 'string' && (text === label ||
    text.split(/\n/).some(part => part.trim() === label) || text.startsWith(label + ' '));
}

export function semanticControlElement(element, label) {
  if (label !== 'Playback position' || element.getAttribute('role') === 'slider') return element;
  return element.querySelector('[role="slider"]') || element;
}

class Page {
  constructor(cdp, sessionId, name) { this.cdp = cdp; this.sessionId = sessionId; this.name = name; }
  evaluate(code) { return this.cdp.evaluate(this.sessionId, code); }
  probe() { return this.evaluate(readProbe); }
  video() { return this.evaluate(readVideo); }
  async semantics() { return this.evaluate(`(()=>{${deepElements}return elements().map(e=>({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),text:e.tagName==='FLT-SEMANTICS'?e.textContent:''})).filter(e=>e.role||e.label);})()`); }
  async rectangle(label) {
    return this.evaluate(`(()=>{${deepElements}const label=${JSON.stringify(label)},matches=(${semanticLabelMatches.toString()}),control=(${semanticControlElement.toString()});const found=elements().filter(e=>{const aria=e.getAttribute('aria-label')||'';return matches(aria,label)||((e.tagName==='FLT-SEMANTICS'||e.getAttribute('role'))&&matches(e.textContent,label));}).map(e=>{const node=control(e,label),r=node.getBoundingClientRect(),role=node.getAttribute('role');const priority=label==='Playback position'?(role==='slider'?0:5):['button','switch','checkbox','combobox','option'].includes(role)?0:3;return{role,priority,x:r.x,y:r.y,width:r.width,height:r.height};}).filter(r=>r.width>0&&r.height>0);found.sort((a,b)=>a.priority-b.priority||(a.width*a.height)-(b.width*b.height));return found[0]||null;})()`);
  }
  async point(x, y) {
    await this.cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, this.sessionId);
    await this.cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 }, this.sessionId);
    await this.cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 }, this.sessionId);
  }
  async click(label) {
    let rectangle;
    await until(async () => Boolean(rectangle = await this.rectangle(label)), `${this.name} semantic ${label}`);
    await this.point(rectangle.x + rectangle.width / 2, rectangle.y + rectangle.height / 2);
  }
  async escape() {
    await this.cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, this.sessionId);
    await this.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, this.sessionId);
  }
  async seek(fraction) {
    const r = await this.rectangle('Playback position'); assert.ok(r, 'Accessible playback slider missing');
    await this.point(r.x + Math.max(8, Math.min(r.width - 8, r.width * fraction)), r.y + r.height / 2);
  }
}

export function verifyFinalizedBootstrap(content, mainSha256) {
  assert.ok(!content.includes('__JMS_MAIN_CONTENT_SHA256__'), 'Run the existing JMS Web bootstrap finalizer first');
  const version = content.match(/\b(?:const|let|var)\s+assetVersion\s*=\s*['"]([a-f0-9]{64})['"]/);
  assert.equal(version?.[1], mainSha256, 'Bootstrap must bind the exact frozen main bundle');
}

export function requiredChromiumArgument(args) {
  const executable = args['--chrome'];
  assert.ok(typeof executable === 'string' && executable.trim() === executable &&
    executable !== '' && path.isAbsolute(executable), 'An explicit absolute --chrome executable is required');
  return executable;
}

function inputFiles(args) {
  assert.equal(args['--go'], true, 'Browser execution requires explicit --go after bundle freeze');
  for (const key of ['--bundle', '--media', '--out', '--chrome', '--expected-main-sha256']) assert.ok(args[key], `Required ${key}`);
  const chrome = fs.realpathSync(requiredChromiumArgument(args));
  assert.ok(fs.statSync(chrome).isFile(), 'The explicit --chrome executable must be a file');
  const bundle = fs.realpathSync(args['--bundle']), media = fs.realpathSync(args['--media']);
  const out = path.resolve(args['--out']);
  const relative = path.relative(EVIDENCE, out);
  assert.ok(relative && !relative.startsWith('..') && !path.isAbsolute(relative), 'Use a fresh run below release-checks/remote-control57');
  assert.ok(!fs.existsSync(out), 'Existing evidence must not be overwritten');
  assert.ok(fs.statSync(media).isFile() && path.extname(media).toLowerCase() === '.mp4', 'Original local MP4 required');
  const main = fs.readFileSync(path.join(bundle, 'main.dart.js'));
  assert.match(args['--expected-main-sha256'], /^[a-f0-9]{64}$/);
  assert.equal(digest(main), args['--expected-main-sha256'], 'Frozen main bundle changed');
  for (const name of ['index.html', 'flutter_bootstrap.js']) {
    verifyFinalizedBootstrap(fs.readFileSync(path.join(bundle, name), 'utf8'), args['--expected-main-sha256']);
  }
  const duration = Number(args['--duration-seconds'] || 30);
  assert.ok(Number.isFinite(duration) && duration >= 12 && duration <= 120);
  return { bundle, media, out, duration, chrome, mainSha256: digest(main) };
}

export async function runBrowserAcceptance(args) {
  const inputs = inputFiles(args);
  fs.mkdirSync(inputs.out, { recursive: true });
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'jms-remote57-'));
  const record = { schemaVersion: 1, passed: false, scope: 'production remote stack and dialog; synthetic account + thin HTML video/TextTrack port',
    physicalDeviceTested: false, productionDeploymentPerformed: false, sourceRoot: ROOT,
    mainSha256: inputs.mainSha256, mediaSha256: digest(fs.readFileSync(inputs.media)),
    runnerSha256: digest(fs.readFileSync(fileURLToPath(import.meta.url))), fixtureSha256: digest(fs.readFileSync(path.join(HERE, 'remote_control_fixture.mjs'))),
    startedAt: new Date().toISOString(), phases: [], contexts: [], browserErrors: [], network: { denied: [], forwarded: 0, tunneled: 0, websocket: [] } };
  const fixture = createRemoteControlFixture({ bundleDir: inputs.bundle, mediaPath: inputs.media, durationTicks: Math.round(inputs.duration * 10000000) });
  let proxy, browser, cdp, receiver, phone;
  const pages = [];
  const phase = async (name, action) => {
    const started = Date.now();
    try { const evidence = await action(); record.phases.push({ name, passed: true, elapsedMs: Date.now() - started, ...evidence }); }
    catch (error) { record.phases.push({ name, passed: false, elapsedMs: Date.now() - started }); throw error; }
  };
  try {
    await fixture.start(); proxy = await loopbackProxy(fixture.origin, record.network);
    browser = spawn(inputs.chrome, ['--headless=new', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
      '--user-data-dir=' + profile, '--proxy-server=http://127.0.0.1:' + proxy.port, '--proxy-bypass-list=<-loopback>',
      '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-extensions', '--disable-default-apps',
      '--no-first-run', '--no-default-browser-check', '--metrics-recording-only', '--password-store=basic', '--use-mock-keychain',
      '--disable-features=MediaRouter,OptimizationHints,NetworkTimeServiceQuerying', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', 'about:blank'],
    { windowsHide: true, stdio: 'ignore' });
    record.ownedBrowserPid = browser.pid;
    const devtools = path.join(profile, 'DevToolsActivePort');
    await until(() => { assert.equal(browser.exitCode, null, 'Owned Chromium exited'); return fs.existsSync(devtools); }, 'owned Chromium CDP', 20000);
    const debugPort = Number(fs.readFileSync(devtools, 'utf8').split(/\r?\n/)[0]);
    const version = await (await fetch(`http://127.0.0.1:${debugPort}/json/version`)).json();
    const endpoint = new URL(version.webSocketDebuggerUrl); assert.equal(endpoint.hostname, '127.0.0.1');
    const socket = new WebSocket(endpoint);
    await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
    cdp = new CDP(socket);
    cdp.handlers.push(event => { if (event.method === 'Runtime.exceptionThrown') record.browserErrors.push({ sessionId: event.sessionId, text: event.params.exceptionDetails.text }); });
    cdp.handlers.push(event => {
      if (!['Network.webSocketCreated', 'Network.webSocketHandshakeResponseReceived', 'Network.webSocketFrameError', 'Network.webSocketClosed'].includes(event.method)) return;
      const entry = { kind: event.method, sessionId: event.sessionId };
      if (event.params.url) { const address = new URL(event.params.url); entry.destination = address.origin + address.pathname; }
      if (event.params.response) entry.status = event.params.response.status;
      if (event.params.errorMessage) entry.error = event.params.errorMessage.replace(/(?:https?|wss?):\/\/\S+/g, '[address omitted]');
      record.network.websocket.push(entry);
    });
    const create = async (role, width, height) => {
      const { browserContextId } = await cdp.send('Target.createBrowserContext', { disposeOnDetach: true });
      const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
      const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
      const page = new Page(cdp, sessionId, role);
      pages.push(page);
      record.contexts.push({ role, browserContextId, targetId, width, height });
      await cdp.send('Runtime.enable', {}, sessionId); await cdp.send('Page.enable', {}, sessionId); await cdp.send('Network.enable', {}, sessionId);
      await cdp.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: role === 'phone' }, sessionId);
      await cdp.send('Page.navigate', { url: `${fixture.origin}/?role=${role}` }, sessionId);
      await until(async () => (await page.probe())?.role === role, `${role} full Flutter semantics`, 90000);
      await page.evaluate(`localStorage.setItem('remote-context-nonce',${JSON.stringify(role)});`);
      return page;
    };
    await phase('two isolated real Flutter browser contexts', async () => {
      receiver = await create('receiver', 1280, 720); phone = await create('phone', 390, 844);
      assert.notEqual(record.contexts[0].browserContextId, record.contexts[1].browserContextId);
      assert.equal(await receiver.evaluate("localStorage.getItem('remote-context-nonce')"), 'receiver');
      assert.equal(await phone.evaluate("localStorage.getItem('remote-context-nonce')"), 'phone');
      return { storageIsolation: true, distinctContextIds: true };
    });
    const selected = async (source = C.sourceA) => {
      await until(async () => (await phone.probe())?.targetSources?.[C.receiver.sessionId] === source, 'current receiver playback discovery');
      await phone.click('Playback device'); await phone.click('Tesla fixture');
      await until(async () => { const state = await phone.probe(); return state?.target === C.receiver.sessionId &&
        state.targetSource === source && state.subtitles.some(value => value.startsWith(source + ':')); }, 'selected current receiver and source metadata');
    };
    const confirmed = async () => {
      await until(async () => (await phone.probe())?.status === 'confirmed', 'fresh receiver progress confirmation');
      const probe = await receiver.probe(), video = await receiver.video();
      const session = fixture.state.sessions.get(C.receiver.sessionId);
      const report = fixture.state.reports.findLast(entry => entry.sessionId === C.receiver.sessionId);
      assert.ok(report && Number.isFinite(Date.parse(session.LastPlaybackCheckIn)), 'Authenticated fresh progress required');
      assert.equal(session.LastPlaybackCheckIn, report.checkIn);
      assert.equal(session.PlaylistItemId, C.playbackId);
      assert.equal(session.PlayState.MediaSourceId, probe.source);
      assert.equal(session.PlayState.SubtitleStreamIndex, probe.subtitle);
      assert.equal(session.PlayState.IsPaused, video.paused);
      assert.ok(Math.abs(session.PlayState.PositionTicks / 10000000 - video.time) < 3, 'Session playhead matches actual video');
      assert.equal(report.body.MediaSourceId, probe.source);
      assert.equal(report.body.SubtitleStreamIndex, probe.subtitle);
      return { probe, video, checkIn: report.checkIn };
    };
    const subtitle = async (label, index, cue) => {
      await phone.click('Subtitles'); await phone.click(index < 0 ? label : label + ' (eng)');
      await until(async () => { const value = await receiver.video(); return (await receiver.probe()).subtitle === index &&
        (index < 0 ? value.tracks.every(track => track.mode === 'disabled') : value.tracks.some(track => track.mode === 'showing' && track.cues.includes(cue))); }, 'actual receiver TextTrack selection');
      await confirmed();
      const report = fixture.state.reports.at(-1); assert.ok(report, 'Receiver report required');
      return { index, cue, actualTextTrack: true };
    };
    await phase('opt in discover and choose same account device', async () => {
      await receiver.click('Start fixture');
      await until(async () => (await receiver.probe())?.started === true, 'real video metadata');
      await receiver.click('Remote control'); await receiver.click('Allow this account to control this device');
      await until(async () => (await receiver.probe())?.receiver === 'enabled', 'receiver enabled');
      await phone.click('Remote control');
      await until(async () => (await phone.probe())?.targets.includes(C.receiver.sessionId), 'discovery');
      assert.deepEqual((await phone.probe()).targets, [C.receiver.sessionId], 'Foreign, stale, disabled and own sessions excluded');
      await selected(); return { excludedNegativeSessions: true };
    });
    await phase('play pause seek verified by video and progress', async () => {
      await phone.click('Play'); await until(async () => !(await receiver.video()).paused, 'HTML video playing'); await confirmed();
      await phone.click('Pause'); await until(async () => (await receiver.video()).paused, 'HTML video paused'); await confirmed();
      await phone.seek(.35); await until(async () => Math.abs((await receiver.video()).time / inputs.duration - .35) < .12, 'HTML video seek'); await confirmed();
      return { video: await receiver.video() };
    });
    await phase('subtitle A Off B and exact MediaSourceId pairing', async () => {
      await subtitle('Source A subtitles', 3, 'SOURCE A SUBTITLE CUE');
      await subtitle('Off', -1, ''); await subtitle('Subtitle B', 7, 'SUBTITLE B CUE');
      await receiver.escape();
      for (const page of [receiver, phone]) {
        const shot = await cdp.send('Page.captureScreenshot', { format: 'png' }, page.sessionId);
        fs.writeFileSync(path.join(inputs.out, page.name + '-subtitle-controls.png'), Buffer.from(shot.data, 'base64'), { flag: 'wx' });
      }
      await receiver.click('Switch source');
      await until(() => fixture.state.sessions.get(C.receiver.sessionId).PlayState?.MediaSourceId === 'source-b', 'source B progress');
      await selected(C.sourceB);
      await until(async () => (await phone.probe()).subtitles.every(value => value.startsWith('source-b:')), 'source-specific metadata');
      await subtitle('Wrong source subtitles', 3, 'WRONG SOURCE SUBTITLE');
      await receiver.click('Switch source');
      await until(() => fixture.state.sessions.get(C.receiver.sessionId).PlayState?.MediaSourceId === 'source-a', 'source A progress');
      await selected(); return { sameIndexDifferentSources: true };
    });
    await phase('204 accepted is not an applied command acknowledgement', async () => {
      fixture.setCommandDelay(1600);
      await phone.click('Play');
      await until(async () => (await phone.probe()).status === 'accepted', '204 accepted state');
      assert.equal((await receiver.video()).paused, true); assert.notEqual((await phone.probe()).status, 'confirmed');
      await until(async () => !(await receiver.video()).paused, 'delayed receiver command'); await confirmed();
      fixture.setCommandDelay(0); fixture.setReportDelay(1600);
      await phone.click('Pause'); await until(async () => (await receiver.video()).paused, 'paused');
      assert.notEqual((await phone.probe()).status, 'confirmed', 'Applied video still requires a fresh server report');
      await confirmed(); fixture.setReportDelay(0);
      return { acceptedBeforeApplied: true, appliedBeforeFreshReport: true };
    });
    await phase('rapid slider gestures settle on the latest accepted position', async () => {
      fixture.setCommandDelay(180, { responseMs: 300 });
      await phone.seek(.2); await phone.seek(.5); await phone.seek(.7);
      await until(async () => (await receiver.video()).time / inputs.duration > .55, 'last rapid seek wins');
      await confirmed(); fixture.setCommandDelay(0);
      const positions = fixture.state.commands.filter(entry => entry.command?.Arguments?.Command === 'Seek').map(entry => entry.command.Arguments.SeekPositionTicks);
      return { commandsObserved: positions.length, finalVideo: await receiver.video() };
    });
    await phase('expired duplicate and foreign-user socket commands do not mutate video', async () => {
      const previous = fixture.state.commands.at(-1).command;
      const before = (await receiver.probe()).mutations;
      fixture.injectCommand(clone(previous));
      const expired = clone(previous); expired.Arguments.JmsRequestId += '-expired'; expired.Arguments.JmsSequence = String(Number(expired.Arguments.JmsSequence) + 100);
      expired.Arguments.JmsIssuedAt = new Date(Date.now() - 20000).toISOString(); expired.Arguments.JmsExpiresAt = new Date(Date.now() - 15000).toISOString();
      fixture.injectCommand(expired);
      const foreign = clone(previous); foreign.ControllingUserId = C.foreignUserId; foreign.Arguments.JmsRequestId += '-foreign'; foreign.Arguments.JmsSequence = String(Number(foreign.Arguments.JmsSequence) + 101);
      fixture.injectCommand(foreign);
      await sleep(450); assert.equal((await receiver.probe()).mutations, before);
      return { mutationsBefore: before, mutationsAfter: (await receiver.probe()).mutations };
    });
    await phase('account switch invalidates delayed controller preflight', async () => {
      fixture.setResponseDelay(1000);
      const before = fixture.state.commands.length;
      const requestStart = fixture.state.requests.length;
      await phone.click('Play');
      await until(() => fixture.state.requests.slice(requestStart).some(entry => entry.role === 'controller' && entry.path === '/Sessions'), 'delayed send preflight started');
      await phone.evaluate("dispatchEvent(new Event('jms-remote-probe-account'))");
      await until(async () => (await phone.probe()).user === C.foreignUserId, 'foreign synthetic account');
      await sleep(1400);
      assert.equal(fixture.state.commands.length, before);
      assert.equal((await phone.probe()).target, null);
      fixture.setResponseDelay(0); await phone.escape(); await phone.click('Change account');
      await until(async () => (await phone.probe()).user === C.userId, 'same synthetic account restored');
      await phone.click('Remote control'); await selected();
      return { crossAccountCommands: 0, accountChangeDuringPreflight: true, syntheticAccountEvent: true };
    });
    await phase('socket disconnect disables receiving and does not replay', async () => {
      const before = (await receiver.probe()).mutations;
      fixture.disconnectReceiver();
      await until(async () => ['disconnected', 'error', 'disabled'].includes((await receiver.probe()).receiver), 'receiver disconnected');
      fixture.setSessionStale(C.receiver.sessionId, true);
      await until(async () => !(await phone.probe()).targets.includes(C.receiver.sessionId), 'stale target removed');
      await sleep(400); assert.equal((await receiver.probe()).mutations, before);
      return { replayedCommands: 0 };
    });
    assert.ok(fixture.state.commands.length >= 8, 'Controls must traverse the server command ledger');
    assert.ok(fixture.state.commands.every(entry => entry.controllingUserId === C.userId &&
      entry.targetSessionId === C.receiver.sessionId && entry.command.ControllingUserId === C.userId), 'Commands remain within the authenticated account and selected receiver');
    assert.deepEqual(fixture.state.failures, [], 'Fixture protocol failure');
    assert.deepEqual(record.browserErrors, [], 'Uncaught browser exception');
    record.passed = true;
  } catch (error) {
    record.error = String(error.stack || error).replaceAll(C.receiver.token, '[synthetic-token]').replaceAll(C.controller.token, '[synthetic-token]');
    for (const page of pages) {
      try { record[page.name + 'FailureState'] = { probe: await page.probe(), video: await page.video(), semantics: await page.semantics() }; } catch {}
      try { const result = await cdp.send('Page.captureScreenshot', { format: 'png' }, page.sessionId); fs.writeFileSync(path.join(inputs.out, page.name + '-failure.png'), Buffer.from(result.data, 'base64'), { flag: 'wx' }); } catch {}
    }
  } finally {
    try { if (cdp) await cdp.send('Browser.close'); } catch {}
    cdp?.close();
    if (browser) {
      await until(() => browser.exitCode !== null, 'owned Chromium exit', 5000).catch(() => browser.kill());
      record.ownedBrowserExited = browser.exitCode !== null;
      if (!record.ownedBrowserExited) {
        await until(() => browser.exitCode !== null, 'terminated owned Chromium exit', 5000).catch(() => {});
        record.ownedBrowserExited = browser.exitCode !== null;
      }
      if (!record.ownedBrowserExited) record.passed = false;
    }
    try { await proxy?.close(); await fixture.close(); record.ownedListenersClosed = true; } catch { record.passed = false; record.ownedListenersClosed = false; }
    record.finishedAt = new Date().toISOString();
    record.ledger = { requests: fixture.state.requests, commands: fixture.state.commands, reports: fixture.state.reports, capabilities: fixture.state.capabilities,
      denied: fixture.state.denied, sockets: fixture.state.sockets, failures: fixture.state.failures };
    fs.writeFileSync(path.join(inputs.out, 'result.json'), JSON.stringify(record, null, 2) + '\n', { flag: 'wx' });
    // Keep the owned profile path as evidence; only its validated temporary root
    // may be removed after browser exit, never a broad Chromium user profile.
    if (record.ownedBrowserExited) {
      const absoluteProfile = fs.realpathSync(profile), temporaryRoot = fs.realpathSync(os.tmpdir());
      assert.ok(absoluteProfile.startsWith(temporaryRoot + path.sep) && /^jms-remote57-[A-Za-z0-9]+$/.test(path.basename(absoluteProfile)));
      fs.rmSync(absoluteProfile, { recursive: true, force: true });
    }
  }
  return record;
}

export function runHarnessUnitChecks() {
  assert.deepEqual(argumentsFor(['--check']), { '--check': true });
  assert.throws(() => argumentsFor(['--unknown']));
  assert.throws(() => argumentsFor(['--bundle']));
  assert.throws(() => argumentsFor(['--go', '--go']));
  assert.throws(() => inputFiles({}));
  assert.throws(() => requiredChromiumArgument({}), /--chrome/);
  assert.throws(() => requiredChromiumArgument({ '--chrome': 'relative-browser' }), /--chrome/);
  assert.throws(() => requiredChromiumArgument({ '--chrome': '   ' }), /--chrome/);
  const explicitBrowser = path.resolve(os.tmpdir(), 'jms-synthetic-chromium');
  assert.equal(requiredChromiumArgument({ '--chrome': explicitBrowser }), explicitBrowser);
  assert.throws(() => inputFiles({ '--go': true, '--bundle': 'unused', '--media': 'unused', '--out': 'unused', '--expected-main-sha256': 'a'.repeat(64) }), /Required --chrome/);
  const hash = 'a'.repeat(64);
  assert.throws(() => verifyFinalizedBootstrap("const assetVersion = '__JMS_MAIN_CONTENT_SHA256__';", hash));
  assert.throws(() => verifyFinalizedBootstrap("const assetVersion = '" + 'b'.repeat(64) + "';", hash));
  verifyFinalizedBootstrap("const assetVersion = '" + hash + "';", hash);
  const origin = 'http://127.0.0.1:32123';
  assert.equal(isOwnedConnectAuthority('127.0.0.1:32123', origin), true);
  for (const authority of ['example.invalid:32123', '127.0.0.1:32124', 'user@127.0.0.1:32123', '127.0.0.1:32123/path', '[::1]:32123', '127.0.0.1.:32123']) {
    assert.equal(isOwnedConnectAuthority(authority, origin), false);
  }
  assert.equal(isOwnedConnectAuthority('127.0.0.1:32123', 'https://127.0.0.1:32123'), false);
  assert.equal(semanticLabelMatches('Playback device\nChoose a playback device', 'Playback device'), true);
  assert.equal(semanticLabelMatches('Source A subtitles (eng)', 'Source A subtitles'), true);
  assert.equal(semanticLabelMatches('Playback device', 'Play'), false);
  assert.equal(semanticLabelMatches(null, 'Play'), false);
  const slider = { getAttribute: () => 'slider' };
  const group = { getAttribute: () => 'group', querySelector: () => slider };
  assert.equal(semanticControlElement(group, 'Playback position'), slider);
  assert.equal(semanticControlElement(slider, 'Playback position'), slider);
  assert.equal(semanticControlElement(group, 'Play'), group);
  const fixture = runFixtureUnitChecks();
  return { status: 'PASS', harnessChecks: 28, fixture, networkStarted: false, browserStarted: false };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = argumentsFor(process.argv.slice(2));
    const result = args['--check'] ? runHarnessUnitChecks() : await runBrowserAcceptance(args);
    process.stdout.write(JSON.stringify(args['--check'] ? result : { passed: result.passed, phases: result.phases.length, error: result.error || null }) + '\n');
    if (result.passed === false) process.exitCode = 1;
  } catch (error) { process.stderr.write(String(error.stack || error) + '\n'); process.exitCode = 1; }
}
