import 'dart:io';

import '../tty.dart';
import 'adapter.dart';

/// Shared doctor auth helpers for host adapters.
Future<bool> authViaWhoami({
  required DoctorContext ctx,
  required List<String> whoamiArgs,
  required String loginCommand,
  required List<String> loginArgs,
  String? tokenEnv,
  List<String> failSubstrings = const [
    'not logged',
    'no access token',
    'unauthorized',
  ],
}) async {
  final bin = ctx.cliPath;
  if (tokenEnv != null &&
      Platform.environment[tokenEnv]?.isNotEmpty == true) {
    ctx.log.ok('$bin  ($tokenEnv set)');
    return true;
  }
  if (ctx.dryRun) {
    ctx.log.ok('$bin  (auth check skipped in dry-run)');
    return true;
  }
  final who =
      await ctx.runner.runCapture(bin, whoamiArgs, allowDryRun: false);
  final out = (who.stdout + who.stderr).toLowerCase();
  if (who.ok &&
      !failSubstrings.any(out.contains) &&
      who.stdout.trim().isNotEmpty) {
    final line = who.stdout.trim().split('\n').first;
    ctx.log.ok('$bin  $line');
    return true;
  }
  ctx.log.warn('$bin not authenticated');
  if (ctx.canLogin) {
    final go = ctx.autoLogin ||
        await confirm('Run `$loginCommand` now?');
    if (go) {
      final r = await ctx.runner
          .run(bin, loginArgs, allowDryRun: false);
      if (r.ok) {
        return authViaWhoami(
          ctx: ctx,
          whoamiArgs: whoamiArgs,
          loginCommand: loginCommand,
          loginArgs: loginArgs,
          tokenEnv: tokenEnv,
          failSubstrings: failSubstrings,
        );
      }
    }
  } else {
    ctx.log.detail(
      tokenEnv != null
          ? 'Set $tokenEnv or run: $loginCommand'
          : 'Run: $loginCommand',
    );
  }
  return false;
}

Future<bool> authViaCommand({
  required DoctorContext ctx,
  required List<String> checkArgs,
  required String loginHint,
}) async {
  final bin = ctx.cliPath;
  if (ctx.dryRun) {
    ctx.log.ok('$bin  (present; auth skipped in dry-run)');
    return true;
  }
  final r =
      await ctx.runner.runCapture(bin, checkArgs, allowDryRun: false);
  if (r.ok) {
    ctx.log.ok('$bin  authenticated / ready');
    return true;
  }
  ctx.log.warn('$bin not authenticated or misconfigured');
  ctx.log.detail('Fix: $loginHint');
  return false;
}

/// Log-only "CLI present" check (no real auth probe).
bool authPresentOnly(DoctorContext ctx, {String? note}) {
  ctx.log.ok(
    '${ctx.cliPath}  (present${note != null ? ' — $note' : ''})',
  );
  return true;
}
