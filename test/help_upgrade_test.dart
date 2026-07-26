import 'package:podfly/src/help.dart';
import 'package:podfly/src/upgrade.dart';
import 'package:podfly/src/version.dart';
import 'package:test/test.dart';

void main() {
  group('version', () {
    test('podflyVersion is semver-like', () {
      expect(podflyVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
      expect(podflyVersionLine(), contains(podflyVersion));
    });
  });

  group('help topics', () {
    test('lists known topics', () {
      expect(helpTopics, containsAll(['create', 'deploy', 'upgrade', 'hosts']));
    });

    test('printHelp overview does not throw', () {
      expect(() => printHelp(), returnsNormally);
      expect(() => printHelp('create'), returnsNormally);
      expect(() => printHelp('deploy'), returnsNormally);
      expect(() => printHelp('upgrade'), returnsNormally);
      expect(() => printHelp('hosts'), returnsNormally);
      expect(() => printHelp('workflow'), returnsNormally);
    });

    test('unknown topic falls back without throwing', () {
      expect(() => printHelp('not-a-real-topic'), returnsNormally);
    });
  });

  group('UpgradeOptions', () {
    test('defaults to pub.dev', () {
      final o = UpgradeOptions();
      expect(o.source, UpgradeSource.pub);
      expect(o.dryRun, isFalse);
    });
  });
}
