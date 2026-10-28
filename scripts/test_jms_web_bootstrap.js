// Exercise the production controller/bootstrap with deterministic DOM and clocks.
// No network, browser profiles, accounts, or application storage are accessed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'web/index.html'), 'utf8');
const controller = html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const retryCode = html.match(/id="jms-startup-retry"[^>]*onclick="([^"]+)"/)[1];
const hash = 'a'.repeat(64);
const bootstrap = fs.readFileSync(path.join(root, 'web/flutter_bootstrap.js'), 'utf8')
  .replace('{{flutter_js}}', '').replace('{{flutter_build_config}}', '')
  .replace('{{flutter_service_worker_version}}', '"worker-v2"')
  .replace('__JMS_MAIN_CONTENT_SHA256__', hash);

function fixture({language = 'en', worker = true, loadError = false,
  storage = new Map()} = {}) {
  const listeners = new Map();
  const timers = new Map();
  let nextTimer = 0;
  const panel = {dataset: {}, removed: false, remove() { this.removed = true; }};
  const message = {textContent: ''};
  const retry = {disabled: false, textContent: ''};
  const state = {loadCalls: 0, registrations: [], reloads: 0, cacheDeletes: 0,
    unregisterCalls: 0};
  const localStorage = {getItem: key => storage.get(key),
    setItem: (key, value) => storage.set(key, value), clear: () => storage.clear()};
  const window = {
    URL,
    addEventListener(name, callback, options) {
      const entries = listeners.get(name) || [];
      entries.push({callback, once: options?.once}); listeners.set(name, entries);
    },
    removeEventListener(name, callback) {
      listeners.set(name, (listeners.get(name) || []).filter(e => e.callback !== callback));
    },
    location: {origin: 'https://example.invalid',
      href: 'https://example.invalid/jms/index.html?private=synthetic',
      hash: '#/synthetic-route', reload() {
        state.reloads++; state.reloadUrl = this.href; state.reloadMethod = 'reload';
      }, replace(url) {
      state.reloads++; state.reloadUrl = url; state.reloadMethod = 'replace';
    }},
    localStorage,
    caches: {async delete() { state.cacheDeletes++; }},
  };
  const navigator = {language};
  if (worker) navigator.serviceWorker = {getRegistrations: async () => [{
    async unregister() { state.unregisterCalls++; }
  }], register(url, options) {
    state.registrations.push({url, options}); return Promise.resolve({});
  }};
  const document = {URL: 'https://example.invalid/jms/index.html?private=synthetic',
    baseURI: 'https://example.invalid/jms/', documentElement: {lang: 'en'},
    getElementById: id => ({'jms-startup': panel, 'jms-startup-message': message,
      'jms-startup-retry': retry})[id]};
  const context = vm.createContext({window, document, navigator, URL, Promise, localStorage,
    caches: window.caches,
    console: {warn() {}},
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, {callback, delay}); return id; },
    clearTimeout(id) { timers.delete(id); },
    _flutter: {buildConfig: {builds: [{mainJsPath: 'main.dart.js'}]}, loader: {
      load(options) { state.loadCalls++; state.options = options;
        return loadError ? Promise.reject(new Error('untrusted detail')) : Promise.resolve(); }
    }}
  });
  const emit = (name, event = {}) => {
    for (const entry of [...(listeners.get(name) || [])]) {
      if (entry.once) window.removeEventListener(name, entry.callback);
      entry.callback(event);
    }
  };
  const clock = maximum => {
    for (const [id, entry] of [...timers]) if (entry.delay <= maximum) {
      timers.delete(id); entry.callback();
    }
  };
  const clickRetry = () => {
    // HTML attribute handlers resolve document properties before Window globals.
    // document.URL is a string, so a bare new URL(...) fails in a real browser.
    if (!retry.disabled) vm.runInContext(`with(document) { (function () { ${retryCode} }).call(document.getElementById('jms-startup-retry')); }`, context);
  };
  vm.runInContext(controller, context);
  return {context, panel, message, retry, state, emit, clock, timers, clickRetry,
    start: () => vm.runInContext(bootstrap, context)};
}

(async () => {
  let checks = 0;
  assert.match(html, /role="status"/);
  assert.match(html, /prefers-reduced-motion/);
  assert.ok(html.indexOf('id="jms-startup"') < html.indexOf('{{flutter_bootstrap_js}}'));
  checks++;

  const first = fixture();
  assert.equal(first.panel.dataset.state, 'loading');
  assert.match(first.message.textContent, /Loading/);
  assert.equal(first.retry.disabled, false);
  first.start();
  assert.equal(first.state.loadCalls, 1);
  assert.equal(first.state.registrations.length, 0);
  assert.equal(Object.hasOwn(first.state.options, 'serviceWorkerSettings'), false);
  assert.equal(first.context._flutter.buildConfig.builds[0].mainJsPath,
    `https://example.invalid/jms/main.dart.js?v=${hash}`);
  checks++;

  let initialized = 0, ran = 0;
  const initializer = {async initializeEngine() { initialized++; return {
    async runApp() { ran++; first.emit('flutter-first-frame'); }
  }; }};
  await first.state.options.onEntrypointLoaded(initializer);
  await first.state.options.onEntrypointLoaded(initializer);
  first.start();
  first.emit('flutter-first-frame');
  first.clock(0);
  assert.equal(initialized, 1); assert.equal(ran, 1);
  assert.equal(first.state.loadCalls, 1);
  assert.equal(first.panel.removed, true);
  assert.equal(first.state.registrations.length, 1);
  assert.equal(first.state.registrations[0].url,
    'https://example.invalid/jms/flutter_service_worker.js?v=worker-v2');
  assert.equal(first.state.registrations[0].options.updateViaCache, 'none');
  checks++;

  const slow = fixture({language: 'zh-TW'}); slow.start();
  slow.clock(12000); assert.equal(slow.panel.dataset.state, 'slow');
  slow.clock(45000); assert.equal(slow.panel.dataset.state, 'timeout');
  assert.match(slow.message.textContent, /繼續等候/);
  slow.emit('flutter-first-frame'); assert.equal(slow.panel.removed, true);
  assert.equal(slow.timers.size, 1); // Only the post-frame, nonblocking SW task.
  checks++;

  const failed = fixture({loadError: true}); failed.start();
  await Promise.resolve(); await Promise.resolve();
  assert.equal(failed.panel.dataset.state, 'error');
  assert.equal(failed.message.textContent.includes('untrusted detail'), false);
  assert.equal(failed.state.registrations.length, 0);
  checks++;

  const badEngine = fixture(); badEngine.start();
  await badEngine.state.options.onEntrypointLoaded({initializeEngine: async () => { throw new Error('private detail'); }});
  assert.equal(badEngine.panel.dataset.state, 'error');
  assert.equal(badEngine.message.textContent.includes('private detail'), false);
  checks++;

  // A stale worker may miss an old versioned entrypoint and fall through to404.
  // Resource failure stays actionable; manual reload retains application storage.
  const accountStorage = new Map([['account', 'synthetic-retained-value']]);
  const stale = fixture({storage: accountStorage}); stale.start();
  stale.emit('error', {target: {tagName: 'SCRIPT'}});
  assert.equal(stale.panel.dataset.state, 'error');
  stale.clickRetry(); stale.clickRetry();
  assert.equal(stale.state.reloads, 1);
  assert.equal(stale.state.reloadUrl, 'https://example.invalid/jms/#/synthetic-route');
  assert.equal(stale.state.reloadMethod, 'replace');
  assert.equal(accountStorage.get('account'), 'synthetic-retained-value');
  assert.equal(stale.state.cacheDeletes, 0);
  assert.equal(stale.state.unregisterCalls, 0);
  const current = fixture({storage: accountStorage}); current.start(); current.emit('flutter-first-frame');
  assert.equal(current.panel.removed, true);
  const rootRetry = fixture(); rootRetry.start();
  rootRetry.context.window.location.href = 'https://example.invalid/jms/#/synthetic-route';
  rootRetry.emit('error', {target: {tagName: 'SCRIPT'}}); rootRetry.clickRetry();
  assert.equal(rootRetry.state.reloadMethod, 'reload');
  assert.equal(rootRetry.state.reloadUrl, 'https://example.invalid/jms/#/synthetic-route');
  checks++;

  const unsupported = fixture({worker: false}); unsupported.start();
  unsupported.emit('flutter-first-frame'); unsupported.clock(0);
  assert.equal(unsupported.panel.removed, true);
  assert.equal(unsupported.state.registrations.length, 0);
  checks++;

  const afterReady = fixture(); afterReady.start(); afterReady.emit('flutter-first-frame');
  afterReady.emit('unhandledrejection', {reason: 'later application event'});
  assert.equal(afterReady.panel.dataset.state, 'loading');
  assert.equal(afterReady.panel.removed, true);
  checks++;
  process.stdout.write(JSON.stringify({passed: checks, storageTouched: false,
    realBrowser: false, productionControllerAndBootstrap: true}) + '\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
