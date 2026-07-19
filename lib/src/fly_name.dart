/// Fly app names are DNS-ish: lowercase letters, digits, hyphens.
String sanitizeFlyAppName(String name) {
  var n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-');
  n = n.replaceAll(RegExp(r'-+'), '-');
  n = n.replaceAll(RegExp(r'^-|-$'), '');
  if (n.isEmpty) n = 'app';
  return n;
}
