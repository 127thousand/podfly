/// Parsed Postgres connection details from a `postgres://` / `postgresql://` URL.
class PostgresUrl {
  const PostgresUrl({
    required this.user,
    required this.password,
    required this.host,
    required this.port,
    required this.database,
    this.requireSsl = false,
  });

  final String user;
  final String password;
  final String host;
  final String port;
  final String database;
  final bool requireSsl;

  Map<String, String> toSidecarMap() => {
        'host': host,
        'port': port,
        'name': database,
        'user': user,
        'password': password,
        'requireSsl': requireSsl ? 'true' : 'false',
      };
}

/// Parse a single Postgres URL. Returns null if [raw] is not a valid URL.
PostgresUrl? parsePostgresUrl(String raw) {
  final s = raw.trim();
  // Allow query params and optional sslmode.
  final m = RegExp(
    r'postgres(?:ql)?://([^:/?#]+):([^@/?#]+)@([^:/?#]+)(?::(\d+))?/([^?"\s#]+)',
    caseSensitive: false,
  ).firstMatch(s);
  if (m == null) return null;

  final user = Uri.decodeComponent(m.group(1)!);
  final password = Uri.decodeComponent(m.group(2)!);
  final host = m.group(3)!;
  final port = m.group(4) ?? '5432';
  final database = Uri.decodeComponent(m.group(5)!);
  final lower = s.toLowerCase();
  final requireSsl = lower.contains('sslmode=require') ||
      lower.contains('sslmode=verify');

  return PostgresUrl(
    user: user,
    password: password,
    host: host,
    port: port,
    database: database,
    requireSsl: requireSsl,
  );
}

/// Find the first `postgres://…` URL in free-form CLI output.
PostgresUrl? parsePostgresUrlFromText(String text) {
  // Prefer explicit DATABASE_URL=… lines from `fly postgres attach`.
  final named = RegExp(
    r'DATABASE_URL\s*=\s*(\S+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (named != null) {
    final u = parsePostgresUrl(named.group(1)!);
    if (u != null) return u;
  }

  final any = RegExp(
    r'''postgres(?:ql)?://[^\s"'<>]+''',
    caseSensitive: false,
  ).firstMatch(text);
  if (any != null) {
    return parsePostgresUrl(any.group(0)!);
  }
  return null;
}
