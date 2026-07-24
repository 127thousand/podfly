import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../fly_name.dart';
import '../hosts/hosts.dart';
import '../log.dart';
import '../process_runner.dart';
import '../tty.dart';

/// Tear down resources described by [PodflyConfig] (demo / nuke).
///
/// Default: API app + static web CDN. Database is **opt-in** (`--database`)
/// so free-tier projects are not deleted by accident.
class Destroyer {
  Destroyer({
    required this.config,
    required this.runner,
    required this.log,
    this.yes = false,
  });

  final PodflyConfig config;
  final ProcessRunner runner;
  final Log log;
  final bool yes;

  Future<void> run({
    bool doApi = true,
    bool doWeb = true,
    bool doDatabase = false,
  }) async {
    ensureHostsRegistered();
    log.step('Destroy plan');

    final plan = <_DestroyItem>[];
    if (doApi) {
      plan.addAll(_planApi());
    }
    if (doWeb && config.web.enabled) {
      plan.addAll(_planWeb());
    }
    if (doDatabase) {
      plan.addAll(_planDatabase());
    }

    if (plan.isEmpty) {
      log.warn('nothing to destroy (check podfly.yaml host / web / flags)');
      return;
    }

    for (final item in plan) {
      log.detail('${item.emoji} ${item.label}');
      log.detail('   → ${item.commandHint}');
    }

    if (runner.dryRun) {
      log.dry('${plan.length} resource(s) would be destroyed');
      return;
    }

    if (!yes) {
      if (!isTty) {
        throw StateError(
          'destroy requires --yes in non-interactive mode '
          '(refusing to nuke cloud resources without confirmation)',
        );
      }
      final ok = await confirm(
        'Destroy ${plan.length} resource(s) above? This cannot be undone.',
        defaultYes: false,
      );
      if (!ok) {
        log.warn('destroy cancelled');
        return;
      }
    }

    log.step('Destroying');
    var failed = 0;
    for (final item in plan) {
      try {
        await log.withSpinner('destroy ${item.label}', () => item.run(runner));
        log.ok(item.label);
      } catch (e) {
        failed++;
        log.err('${item.label}: $e');
      }
    }

    if (failed > 0) {
      throw StateError('destroy finished with $failed failure(s)');
    }
    log.ok('all targeted resources destroyed');
    log.tip('local podfly.yaml left in place — delete or re-init as needed');
  }

  List<_DestroyItem> _planApi() {
    final host = config.host;
    switch (host) {
      case AppHost.fly:
        final app = sanitizeFlyAppName(config.fly.app);
        return [
          _DestroyItem(
            emoji: '🟣',
            label: 'Fly app $app',
            commandHint: 'fly apps destroy $app --yes',
            run: (r) async {
              final code = await r.run('fly', ['apps', 'destroy', app, '--yes']);
              if (!code.ok && !r.dryRun) {
                // try flyctl alias
                final c2 =
                    await r.run('flyctl', ['apps', 'destroy', app, '--yes']);
                if (!c2.ok) {
                  throw StateError('fly apps destroy failed (${code.exitCode})');
                }
              }
            },
          ),
        ];
      case AppHost.railway:
        final project = config.railway?.project ?? config.name;
        return [
          _DestroyItem(
            emoji: '🚂',
            label: 'Railway project $project (manual if CLI lacks delete)',
            commandHint:
                'railway down / dashboard delete project "$project"',
            run: (r) async {
              // Best-effort: newer CLI may support project delete.
              final c = await r.run(
                'railway',
                ['down', '--yes'],
                workingDirectory: config.root,
              );
              if (!c.ok) {
                log.warn(
                  'railway down failed — delete project in dashboard: $project',
                );
              }
            },
          ),
        ];
      case AppHost.digitalOcean:
        final app = config.digitalOcean?.app ?? config.name;
        return [
          _DestroyItem(
            emoji: '🌊',
            label: 'DigitalOcean app $app',
            commandHint: 'doctl apps delete <id> --force (list: doctl apps list)',
            run: (r) async {
              final list = await r.runCapture(
                'doctl',
                ['apps', 'list', '--format', 'ID,Spec.Name', '--no-header'],
              );
              final id = _matchDoAppId(list.stdout, app);
              if (id == null) {
                log.warn('DO app "$app" not found in doctl apps list');
                return;
              }
              final c =
                  await r.run('doctl', ['apps', 'delete', id, '--force']);
              if (!c.ok) {
                throw StateError('doctl apps delete failed');
              }
            },
          ),
        ];
      case AppHost.render:
        return [
          _DestroyItem(
            emoji: '🟦',
            label: 'Render service ${config.render?.service ?? config.name}',
            commandHint: 'Delete in Render dashboard (CLI delete varies by plan)',
            run: (r) async {
              log.warn(
                'Render: open dashboard and delete service '
                '${config.render?.service ?? config.name}',
              );
            },
          ),
        ];
      case AppHost.cloudRun:
        final svc = config.cloudRun?.service ?? config.name;
        final region = config.cloudRun?.region ?? 'us-central1';
        return [
          _DestroyItem(
            emoji: '☁️',
            label: 'Cloud Run $svc',
            commandHint: 'gcloud run services delete $svc --region $region --quiet',
            run: (r) async {
              final c = await r.run('gcloud', [
                'run',
                'services',
                'delete',
                svc,
                '--region',
                region,
                '--quiet',
              ]);
              if (!c.ok) throw StateError('gcloud run delete failed');
            },
          ),
        ];
      case AppHost.aws:
      case AppHost.awsEcs:
      case AppHost.azure:
      case AppHost.hetzner:
        return [
          _DestroyItem(
            emoji: '📦',
            label: '${host.yamlName} API (${config.name})',
            commandHint:
                'Tear down via cloud console / host CLI — see doc for ${host.yamlName}',
            run: (r) async {
              log.warn(
                'Automatic destroy not implemented for ${host.yamlName} yet — '
                'remove resources in the provider console.',
              );
            },
          ),
        ];
    }
  }

  List<_DestroyItem> _planWeb() {
    // Only destroy a *separate* static CDN project when we actually deployed one.
    // - monolith: UI is inside the API container (Cloud Run nginx, Fly, …)
    // - native web hosts (Railway/DO/Render): UI is a host service, not Pages
    // - web disabled: nothing
    if (!config.web.enabled) {
      log.detail('web.enabled: false — no separate UI resource to destroy');
      return [];
    }
    if (config.mode == DeployMode.monolith) {
      log.detail(
        'mode: monolith — UI ships with the API service '
        '(no Cloudflare/Vercel/Netlify project to delete)',
      );
      return [];
    }
    if (!config.usesStaticWebHost) {
      log.detail(
        'web is on the API host (native web), not a third-party CDN — '
        'no separate Pages/Vercel/Netlify delete',
      );
      return [];
    }

    switch (config.webHost) {
      case StaticWebHost.cloudflare:
        final project = sanitizeFlyAppName(
          config.cloudflare?.project ?? config.name,
        );
        return [
          _DestroyItem(
            emoji: '🟠',
            label: 'Cloudflare Pages $project',
            commandHint: 'wrangler pages project delete $project --yes',
            run: (r) async {
              final c = await r.run(
                'wrangler',
                ['pages', 'project', 'delete', project, '--yes'],
              );
              if (!c.ok) {
                throw StateError('wrangler pages project delete failed');
              }
            },
          ),
        ];
      case StaticWebHost.vercel:
        final project = config.vercel?.project ?? config.name;
        return [
          _DestroyItem(
            emoji: '▲',
            label: 'Vercel project $project',
            commandHint: 'vercel project rm $project --yes',
            run: (r) async {
              final args = <String>['project', 'rm', project, '--yes'];
              final scope = config.vercel?.scope;
              if (scope != null && scope.isNotEmpty) {
                args.addAll(['--scope', scope]);
              }
              final c = await r.run('vercel', args);
              if (!c.ok) throw StateError('vercel project rm failed');
            },
          ),
        ];
      case StaticWebHost.netlify:
        final siteId = config.netlify?.siteId;
        final site = config.netlify?.site ?? config.name;
        return [
          _DestroyItem(
            emoji: '🟢',
            label: 'Netlify site ${siteId ?? site}',
            commandHint: siteId != null
                ? 'netlify sites:delete $siteId --force'
                : 'netlify sites:delete --force (set site_id in podfly.yaml)',
            run: (r) async {
              if (siteId == null || siteId.isEmpty) {
                log.warn(
                  'netlify.site_id missing — try: netlify sites:list, then '
                  'netlify sites:delete <id> --force',
                );
                return;
              }
              final c = await r.run(
                'netlify',
                ['sites:delete', siteId, '--force'],
              );
              if (!c.ok) throw StateError('netlify sites:delete failed');
            },
          ),
        ];
      case StaticWebHost.githubPages:
        return [
          _DestroyItem(
            emoji: '🐙',
            label: 'GitHub Pages '
                '${config.githubPages?.repo ?? config.name} (gh-pages branch)',
            commandHint:
                'gh api -X DELETE … or delete gh-pages branch / disable Pages',
            run: (r) async {
              final g = config.githubPages;
              final repo = g?.repo ?? config.name;
              final owner = g?.owner;
              if (owner == null) {
                log.warn(
                  'github_pages.owner missing — delete gh-pages branch manually',
                );
                return;
              }
              // Best-effort: delete gh-pages branch
              final c = await r.run('gh', [
                'api',
                '-X',
                'DELETE',
                'repos/$owner/$repo/git/refs/heads/${g?.branch ?? 'gh-pages'}',
              ]);
              if (!c.ok) {
                log.warn(
                  'could not delete Pages branch — disable in repo Settings → Pages',
                );
              }
            },
          ),
        ];
    }
  }

  List<_DestroyItem> _planDatabase() {
    switch (config.database.provider) {
      case DatabaseProvider.none:
      case DatabaseProvider.sqlite:
        return [];
      case DatabaseProvider.flyPostgres:
        final app = config.database.flyPostgres?.app ?? '${config.name}-db';
        return [
          _DestroyItem(
            emoji: '🗄️',
            label: 'Fly Postgres $app',
            commandHint: 'fly apps destroy $app --yes',
            run: (r) async {
              final c =
                  await r.run('fly', ['apps', 'destroy', app, '--yes']);
              if (!c.ok) throw StateError('fly postgres app destroy failed');
            },
          ),
        ];
      case DatabaseProvider.supabase:
        final ref = config.database.supabase?.projectRef;
        return [
          _DestroyItem(
            emoji: '⚡',
            label: 'Supabase project ${ref ?? config.database.supabase?.projectName ?? '?'}',
            commandHint: ref != null
                ? 'supabase projects delete $ref --yes'
                : 'supabase projects delete <ref> --yes',
            run: (r) async {
              if (ref == null || ref.isEmpty) {
                log.warn('database.supabase.project_ref missing');
                return;
              }
              final c = await r.run(
                'supabase',
                ['projects', 'delete', ref, '--yes'],
              );
              if (!c.ok) {
                throw StateError('supabase projects delete failed');
              }
              final sidecar = File(p.join(
                config.serverPath,
                'config',
                '.podfly_supabase_pg.json',
              ));
              if (await sidecar.exists()) await sidecar.delete();
            },
          ),
        ];
      case DatabaseProvider.neon:
        return [
          _DestroyItem(
            emoji: '🟢',
            label: 'Neon project (manual / neonctl)',
            commandHint: 'neonctl projects delete <id>',
            run: (r) async {
              log.warn(
                'Neon: delete the project in console or via neonctl — '
                'id not always stored in podfly.yaml',
              );
            },
          ),
        ];
      case DatabaseProvider.railwayPostgres:
      case DatabaseProvider.digitalOceanPostgres:
      case DatabaseProvider.renderPostgres:
        return [
          _DestroyItem(
            emoji: '🗄️',
            label: '${config.database.provider.name} database',
            commandHint: 'Delete via provider dashboard / CLI',
            run: (r) async {
              log.warn(
                'Auto-delete not implemented for '
                '${config.database.provider.name} — use provider console',
              );
            },
          ),
        ];
    }
  }

  static String? _matchDoAppId(String listOut, String appName) {
    final want = sanitizeFlyAppName(appName);
    for (final line in listOut.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final id = parts.first;
      final name = parts.sublist(1).join(' ');
      if (name == appName || sanitizeFlyAppName(name) == want) return id;
    }
    return null;
  }
}

class _DestroyItem {
  _DestroyItem({
    required this.emoji,
    required this.label,
    required this.commandHint,
    required this.run,
  });

  final String emoji;
  final String label;
  final String commandHint;
  final Future<void> Function(ProcessRunner runner) run;
}
