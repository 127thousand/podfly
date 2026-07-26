/// Fly app names are DNS-ish: lowercase letters, digits, hyphens.
String sanitizeFlyAppName(String name) {
  var n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-');
  n = n.replaceAll(RegExp(r'-+'), '-');
  n = n.replaceAll(RegExp(r'^-|-$'), '');
  if (n.isEmpty) n = 'app';
  return n;
}

/// Whether `fly apps create` failed because the name is unavailable.
///
/// Matches Fly API messages such as:
/// `Validation failed: Name has already been taken`.
bool isFlyAppNameConflict(String combinedOutput) {
  final e = combinedOutput.toLowerCase();
  if (e.contains('already been taken')) return true;
  if (e.contains('name has already been taken')) return true;
  if (e.contains('name is already taken')) return true;
  if (e.contains('already exists') && e.contains('name')) return true;
  // Broad fallback: "taken" near name/validation (avoid matching unrelated text).
  if (e.contains('taken') &&
      (e.contains('name') || e.contains('validation'))) {
    return true;
  }
  return false;
}

/// Next candidate after a global name collision (preferred-ab12).
///
/// [attempt] should be ≥ 1 (attempt 0 is the bare preferred name).
String nextFlyAppNameCandidate(String preferred, int attempt) {
  final n = attempt < 1 ? 1 : attempt;
  final mixed = (n * 0x9E37) ^ preferred.hashCode;
  final suffix =
      (mixed & 0xFFFF).toRadixString(16).padLeft(4, '0');
  var candidate = '$preferred-$suffix';
  // Keep names short for DNS / Fly UX (max 63; we stay under ~30).
  if (candidate.length > 30) {
    final maxHead = 30 - 1 - suffix.length;
    final head = preferred.length <= maxHead
        ? preferred
        : preferred.substring(0, maxHead);
    candidate = '$head-$suffix';
  }
  return sanitizeFlyAppName(candidate);
}
