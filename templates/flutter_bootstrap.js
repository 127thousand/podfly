// Custom bootstrap — processed by `flutter build web` ({{…}} tokens expanded).
// https://docs.flutter.dev/platform-integration/web/initialization
// Installed by podfly when web.patch_bootstrap: true
{{flutter_js}}
{{flutter_build_config}}

// Flutter's default service worker is a no-op that unregisters itself and
// force-navigates open tabs. That makes every visit feel like a cold load of
// the multi‑MB CanvasKit wasm. Unregister leftovers and do not re-register.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then((regs) => {
    for (const reg of regs) {
      reg.unregister();
    }
  });
}

_flutter.loader.load({
  config: {
    // Same-origin CanvasKit so host Cache-Control applies.
    canvasKitBaseUrl: 'canvaskit/',
  },
});
