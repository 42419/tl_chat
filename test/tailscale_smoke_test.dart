// Minimal smoke test for the `tailscale` dependency.
//
// This exercises the package's public API surface at the pure-Dart level:
// the singleton shape and the usage guards that throw before any native code
// is touched. It therefore runs on any host without a tailnet, auth key, or a
// native asset build, and proves the dependency resolves and works.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('tailscale dependency smoke test', () {
    test('Tailscale.instance is a singleton', () {
      expect(identical(Tailscale.instance, Tailscale.instance), isTrue);
    });

    test('runtime methods require Tailscale.init first', () async {
      final tailscale = Tailscale.instance;

      await _expectUsageError(() => tailscale.up(authKey: 'test-auth-key'));
      await _expectUsageError(tailscale.status);
      await _expectUsageError(tailscale.nodes);
      await _expectUsageError(() => tailscale.nodeByIp('100.64.0.1'));
      await _expectUsageError(() => tailscale.whois('100.64.0.1'));
      await _expectUsageError(tailscale.down);
      await _expectUsageError(tailscale.logout);
    });

    test('init rejects an empty or blank stateDir', () {
      expect(
        () => Tailscale.init(stateDir: ''),
        throwsA(isA<TailscaleUsageException>()),
      );
      expect(
        () => Tailscale.init(stateDir: '   '),
        throwsA(isA<TailscaleUsageException>()),
      );
    });
  });
}

Future<void> _expectUsageError(FutureOr<Object?> Function() call) async {
  await expectLater(call(), throwsA(isA<TailscaleUsageException>()));
}
