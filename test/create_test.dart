import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:podfly/src/config.dart';
import 'package:podfly/src/create.dart';
import 'package:podfly/src/hosts/hosts.dart';
import 'package:podfly/src/log.dart';
import 'package:podfly/src/process_runner.dart';
import 'package:test/test.dart';

void main() {
  ensureHostsRegistered();

  group('parseCreateKind', () {
    test('aliases', () {
      expect(parseCreateKind('app-backend'), CreateKind.appBackend);
      expect(parseCreateKind('fullstack'), CreateKind.appBackend);
      expect(parseCreateKind('app_only'), CreateKind.appOnly);
      expect(parseCreateKind('flutter'), CreateKind.appOnly);
      expect(parseCreateKind('backend-only'), CreateKind.backendOnly);
      expect(parseCreateKind('server'), CreateKind.backendOnly);
      expect(parseCreateKind(null), isNull);
      expect(parseCreateKind(''), isNull);
    });

    test('unknown throws', () {
      expect(() => parseCreateKind('grpc'), throwsFormatException);
    });
  });

  group('parseCreateSurfaces', () {
    test('mobile and web', () {
      final s = parseCreateSurfaces('mobile,web')!;
      expect(s.mobile, isTrue);
      expect(s.web, isTrue);
      expect(s.apiOnly, isFalse);
    });

    test('web only', () {
      final s = parseCreateSurfaces('web')!;
      expect(s.mobile, isFalse);
      expect(s.web, isTrue);
    });

    test('mobile only is apiOnly', () {
      final s = parseCreateSurfaces('mobile')!;
      expect(s.apiOnly, isTrue);
    });

    test('desktop accepted but ignored', () {
      final s = parseCreateSurfaces('mobile,desktop')!;
      expect(s.mobile, isTrue);
      expect(s.web, isFalse);
    });

    test('empty / unknown', () {
      expect(parseCreateSurfaces(null), isNull);
      expect(() => parseCreateSurfaces('tv'), throwsFormatException);
      expect(() => parseCreateSurfaces('desktop'), throwsFormatException);
    });
  });

  group('parseCreateDatabase', () {
    test('aliases', () {
      expect(parseCreateDatabase('none'), DatabaseProvider.none);
      expect(parseCreateDatabase('neon'), DatabaseProvider.neon);
      expect(parseCreateDatabase('fly_postgres'), DatabaseProvider.flyPostgres);
      expect(parseCreateDatabase('fly'), DatabaseProvider.flyPostgres);
      expect(parseCreateDatabase(null), isNull);
    });

    test('unknown throws', () {
      expect(() => parseCreateDatabase('aurora'), throwsFormatException);
    });
  });

  group('CreateOptions.resolvedTemplate', () {
    CreateOptions opts({
      CreateKind kind = CreateKind.appBackend,
      DatabaseProvider database = DatabaseProvider.none,
      String? template,
    }) =>
        CreateOptions(
          name: 'demo',
          parentDir: '/tmp',
          kind: kind,
          surfaces: CreateSurfaces.mobileWeb,
          host: AppHost.fly,
          mode: DeployMode.split,
          database: database,
          template: template,
        );

    test('app-backend none → mini', () {
      expect(opts().resolvedTemplate, 'mini');
    });

    test('app-backend neon → fullstack', () {
      expect(
        opts(database: DatabaseProvider.neon).resolvedTemplate,
        'fullstack',
      );
    });

    test('backend-only → server', () {
      expect(
        opts(kind: CreateKind.backendOnly).resolvedTemplate,
        'server',
      );
      expect(
        opts(
          kind: CreateKind.backendOnly,
          database: DatabaseProvider.neon,
        ).resolvedTemplate,
        'server',
      );
    });

    test('explicit template wins', () {
      expect(
        opts(
          database: DatabaseProvider.neon,
          template: 'mini',
        ).resolvedTemplate,
        'mini',
      );
    });

    test('wantsMobileCi only for mobile-only app kinds', () {
      expect(
        CreateOptions(
          name: 'm',
          parentDir: '/tmp',
          kind: CreateKind.appBackend,
          surfaces: const CreateSurfaces(mobile: true),
          host: AppHost.fly,
          mode: DeployMode.monolith,
          database: DatabaseProvider.none,
        ).wantsMobileCi,
        isTrue,
      );
      expect(
        CreateOptions(
          name: 'm',
          parentDir: '/tmp',
          kind: CreateKind.appBackend,
          surfaces: CreateSurfaces.mobileWeb,
          host: AppHost.fly,
          mode: DeployMode.split,
          database: DatabaseProvider.none,
        ).wantsMobileCi,
        isFalse,
      );
    });
  });

  group('Creator dry-run', () {
    test('plans app-backend without writing files', () async {
      final parent = await Directory.systemTemp.createTemp('podfly_create_');
      final name = 'demo_create_${DateTime.now().millisecondsSinceEpoch}';
      final log = Log(quiet: true);
      final runner = ProcessRunner(log: log, dryRun: true);

      final cfg = await Creator(log: log, runner: runner, yes: true).run(
        nameArg: name,
        directoryArg: parent.path,
        kindFlag: CreateKind.appBackend,
        surfacesFlag: CreateSurfaces.mobileWeb,
        hostFlag: AppHost.fly,
        modeFlag: DeployMode.split,
      );

      expect(cfg.name, name);
      expect(cfg.server, '${name}_server');
      expect(cfg.flutter, '${name}_flutter');
      expect(cfg.mode, DeployMode.split);
      expect(cfg.web.enabled, isTrue);
      expect(cfg.host, AppHost.fly);
      expect(cfg.database.provider, DatabaseProvider.none);

      final project = Directory(p.join(parent.path, name));
      expect(await project.exists(), isFalse);
      expect(await File(p.join(parent.path, name, 'podfly.yaml')).exists(),
          isFalse);

      await parent.delete(recursive: true);
    });

    test('database neon plans fullstack + neon config', () async {
      final parent = await Directory.systemTemp.createTemp('podfly_create_db_');
      final log = Log(quiet: true);
      final cfg = await Creator(
        log: log,
        runner: ProcessRunner(log: log, dryRun: true),
        yes: true,
      ).run(
        nameArg: 'with_db',
        directoryArg: parent.path,
        kindFlag: CreateKind.appBackend,
        databaseFlag: DatabaseProvider.neon,
      );

      expect(cfg.database.provider, DatabaseProvider.neon);
      expect(cfg.database.neon?.projectName, 'with_db');
      await parent.delete(recursive: true);
    });

    test('template flag implies db when no --database', () async {
      final parent = await Directory.systemTemp.createTemp('podfly_create_t_');
      final log = Log(quiet: true);
      final cfg = await Creator(
        log: log,
        runner: ProcessRunner(log: log, dryRun: true),
        yes: true,
      ).run(
        nameArg: 'full_t',
        directoryArg: parent.path,
        kindFlag: CreateKind.appBackend,
        templateFlag: 'fullstack',
      );

      expect(cfg.database.provider, DatabaseProvider.neon);
      await parent.delete(recursive: true);
    });

    test('backend-only disables web', () async {
      final parent = await Directory.systemTemp.createTemp('podfly_create_be_');
      final log = Log(quiet: true);
      final cfg = await Creator(
        log: log,
        runner: ProcessRunner(log: log, dryRun: true),
        yes: true,
      ).run(
        nameArg: 'api_only',
        directoryArg: parent.path,
        kindFlag: CreateKind.backendOnly,
        hostFlag: AppHost.cloudRun,
      );

      expect(cfg.web.enabled, isFalse);
      expect(cfg.mode, DeployMode.monolith);
      expect(cfg.host, AppHost.cloudRun);
      await parent.delete(recursive: true);
    });

    test('mobile-only forces monolith + codemagic', () async {
      final parent = await Directory.systemTemp.createTemp('podfly_create_m_');
      final log = Log(quiet: true);
      final cfg = await Creator(
        log: log,
        runner: ProcessRunner(log: log, dryRun: true),
        yes: true,
      ).run(
        nameArg: 'mobile_app',
        directoryArg: parent.path,
        kindFlag: CreateKind.appBackend,
        surfacesFlag: const CreateSurfaces(mobile: true),
        modeFlag: DeployMode.split, // ignored when no web
      );

      expect(cfg.web.enabled, isFalse);
      expect(cfg.mode, DeployMode.monolith);
      expect(cfg.mobile.provider, MobileProvider.codemagic);
      await parent.delete(recursive: true);
    });

    test('sanitizes project name', () async {
      final parent = await Directory.systemTemp.createTemp('podfly_create_s_');
      final log = Log(quiet: true);
      final cfg = await Creator(
        log: log,
        runner: ProcessRunner(log: log, dryRun: true),
        yes: true,
      ).run(
        nameArg: 'My-Cool App!',
        directoryArg: parent.path,
        kindFlag: CreateKind.appBackend,
      );

      expect(cfg.name, 'my_cool_app');
      await parent.delete(recursive: true);
    });
  });
}
