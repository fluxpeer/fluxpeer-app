// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Mock-fallback gating: a production build must NOT silently fall
// back to the in-memory mock when the native host raises a REAL error (a
// token-gated control 401, a schema mismatch, etc.). Such errors must propagate
// so acceptance sees the real failure instead of a "connected-looking" mock.
//
// Contract under test: only `MissingPluginException` may
// ever enable the mock, and only when the build opts in via
// `--dart-define=FLUXPEER_ALLOW_MOCK=true`. Any OTHER exception always
// propagates, regardless of the flag. This test runs with the default (flag
// off) and feeds a PlatformException, so it holds independent of the flag.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxpeer/channel/fluxpeer_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluxpeer.app/flux');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'getCurrentState propagates a native/control error, does not silent-mock',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        // Simulate the hardened-server case: device endpoints return 401.
        throw PlatformException(code: 'unauthorized', message: 'gateway 401');
      });

      await expectLater(
        FluxpeerChannel.getCurrentState(),
        throwsA(isA<PlatformException>()),
      );
      expect(
        FluxpeerChannel.usingMock,
        isFalse,
        reason: 'a real native/control error must not silently enable mock',
      );
    },
  );

  test(
    'permissionStatus propagates a native/control error, does not silent-mock',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unauthorized', message: 'perm 401');
      });

      await expectLater(
        FluxpeerChannel.permissionStatus(),
        throwsA(isA<PlatformException>()),
      );
      expect(FluxpeerChannel.usingMock, isFalse);
    },
  );
}
