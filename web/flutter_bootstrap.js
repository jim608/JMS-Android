{{flutter_js}}
{{flutter_build_config}}

(() => {
  const startup = window.jmsStartup;
  if (!startup || !startup.begin()) return;
  // Filled from the actual main.dart.js bytes by the Web-only build step.
  const assetVersion = '__JMS_MAIN_CONTENT_SHA256__';
  const serviceWorkerVersion = {{flutter_service_worker_version}};
  const versioned = /^[a-f0-9]{64}$/.test(assetVersion);
  // flutter run has no service worker; release output must be finalized first.
  if (serviceWorkerVersion != null && !versioned) { startup.fail(); return; }
  if (versioned) {
    for (const build of _flutter.buildConfig.builds) {
      if (build.mainJsPath) {
        const entrypoint = new URL(build.mainJsPath, document.baseURI);
        entrypoint.searchParams.set('v', assetVersion);
        build.mainJsPath = entrypoint.toString();
      }
    }
  }
  // Do not make the first frame wait for SW installation/activation. The
  // generated worker retains its resource manifest and normal update protocol.
  window.addEventListener('flutter-first-frame', () => {
    if (!versioned || serviceWorkerVersion == null || !('serviceWorker' in navigator)) return;
    const register = () => {
      const url = new URL('flutter_service_worker.js', document.baseURI);
      url.searchParams.set('v', String(serviceWorkerVersion));
      try {
        navigator.serviceWorker.register(url.toString(), {updateViaCache: 'none'})
          .catch(() => console.warn('JMS offline cache update could not finish.'));
      } catch (_) { console.warn('JMS offline cache update could not finish.'); }
    };
    if ('requestIdleCallback' in window) window.requestIdleCallback(register, {timeout: 1000});
    else setTimeout(register, 0);
  }, {once: true});
  let engineStarted = false;
  try {
    Promise.resolve(_flutter.loader.load({
      onEntrypointLoaded: async (initializer) => {
        if (engineStarted) return;
        engineStarted = true;
        startup.stage();
        try {
          const runner = await initializer.initializeEngine();
          await runner.runApp();
        } catch (_) { startup.fail(); }
      }
    })).catch(startup.fail);
  } catch (_) { startup.fail(); }
})();
