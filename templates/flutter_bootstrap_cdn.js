// Custom bootstrap — CDN / wasm builds (no forced same-origin CanvasKit).
// https://docs.flutter.dev/platform-integration/web/initialization
// Installed by podfly when web.build is canvaskit_cdn or wasm.
{{flutter_js}}
{{flutter_build_config}}

// Unregister Flutter’s default service worker (cold-load thrash).
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then((regs) => {
    for (const reg of regs) {
      reg.unregister();
    }
  });
}

_flutter.loader.load({
  config: {
    // Leave CanvasKit / skwasm URLs to Flutter defaults (CDN or build output).
  },
});
