/// Sync [web.api_url] / dart-define values inside existing mobile CI files.
///
/// Updates only URL assignments for [defineName] (default `SERVER_URL`), leaving
/// the rest of the file intact. Lines get a trailing `# podfly:api_url` marker
/// so future deploys can find them reliably.
class MobileApiUrlSync {
  MobileApiUrlSync._();

  static const marker = 'podfly:api_url';

  /// Normalize for `--dart-define` / env vars (no trailing slash).
  static String apiForDefine(String apiUrl) {
    final t = apiUrl.trim();
    if (t.endsWith('/') && t.length > 8) {
      return t.substring(0, t.length - 1);
    }
    return t;
  }

  /// Result of syncing [content].
  static ({String text, bool changed, int replacements}) apply(
    String content, {
    required String defineName,
    required String apiUrl,
  }) {
    final api = apiForDefine(apiUrl);
    if (api.isEmpty || defineName.isEmpty) {
      return (text: content, changed: false, replacements: 0);
    }

    var text = content;
    var n = 0;

    // YAML / env: "        SERVER_URL: https://old  # optional comment"
    final yamlRe = RegExp(
      r'^([ \t]*' +
          RegExp.escape(defineName) +
          r':[ \t]*)(https?://\S+)([ \t]*(#.*)?)?$',
      multiLine: true,
    );
    text = text.replaceAllMapped(yamlRe, (m) {
      final prefix = m.group(1)!;
      final old = apiForDefine(m.group(2)!);
      if (old == api && (m.group(3)?.contains(marker) ?? false)) {
        return m.group(0)!;
      }
      n++;
      return '$prefix$api  # $marker';
    });

    // CLI: --dart-define=SERVER_URL=https://old  (optional trailing backslash/space)
    final defineRe = RegExp(
      r'(--dart-define=' +
          RegExp.escape(defineName) +
          r'=)(https?://[^\s\\]+)',
    );
    text = text.replaceAllMapped(defineRe, (m) {
      final old = apiForDefine(m.group(2)!);
      if (old == api) return m.group(0)!;
      n++;
      return '${m.group(1)}$api';
    });

    return (text: text, changed: n > 0 && text != content, replacements: n);
  }
}
