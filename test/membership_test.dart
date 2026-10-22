// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:fluxpeer/models/models.dart';
import 'package:fluxpeer/state/app_controller.dart';
import 'package:fluxpeer/channel/fluxpeer_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluxpeer.app/flux');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const one = FxNetwork(id: 'net-1', name: 'one', controlUrl: 'https://a.example', deviceId: 'dev-1', pubkey: 'public');
  const two = FxNetwork(id: 'net-1', name: 'two', controlUrl: 'https://b.example', deviceId: 'dev-1');
  late Directory dir;
  late AppController controller;
  late GetStorage storage;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fluxpeer-membership-test-');
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    storage = GetStorage(dir.path.split('/').last, dir.path);
    await storage.initStorage;
    controller = AppController(storage: storage);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await dir.delete(recursive: true);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
  });
  test('membership identity separates controllers/devices and normalizes origin', () {
    expect(one.key, isNot(two.key));
    expect(one.key, membershipKey('https://A.example:443/path', 'net-1', 'dev-1'));
    expect(one.key, isNot(membershipKey(one.controlUrl, one.id, 'dev-2')));
    expect(one.key, 'v2.aHR0cHM6Ly9hLmV4YW1wbGU.bmV0LTE.ZGV2LTE');
  });
  test('legacy active id migrates only when its complete membership is unique', () async {
    await storage.write('networks', [one.toJson()]);
    await storage.write('activeId', one.id);
    messenger.setMockMethodCallHandler(channel, (call) async => {'state': 'disconnected', 'peers': []});
    const events = MethodChannel('dev.fluxpeer.app/fluxStatus');
    messenger.setMockMethodCallHandler(events, (call) async => null);
    controller.onInit();
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeId.value, one.key);
    expect(storage.read<String>('activeId'), one.key);
    controller.onClose();
    await storage.write('networks', [one.toJson(), two.toJson()]);
    await storage.write('activeId', one.id);
    controller = AppController(storage: storage)..onInit();
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeId.value, isNull);
    expect(storage.read<String>('activeId'), isNull);
    controller.onClose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(events, null);
  });
  test('failed native leave retains UI; success removes exactly its member', () async {
    controller.networks.addAll([one, two]); controller.activeId.value = one.key;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'leave');
      expect(jsonDecode((call.arguments as Map)['network'])['controlUrl'], one.controlUrl);
      throw PlatformException(code: 'leave_failed', message: 'stop failed');
    });
    await expectLater(controller.leave(one.key), throwsA(isA<PlatformException>()));
    expect(controller.networks, [one, two]); expect(controller.activeId.value, one.key);
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await controller.leave(one.key);
    expect(controller.networks, [two]); expect(controller.activeId.value, two.key);
  });
  test('backups strip connection material and every restored entry requires rejoin', () async {
    controller.networks.add(one);
    final backup = controller.exportBackup();
    final data = (jsonDecode(backup) as List).single as Map;
    expect(data.containsKey('pubkey'), isFalse);
    expect(data.containsKey('overlayV4'), isFalse);
    expect(data['needsRejoin'], true);
    controller.networks.clear();
    expect(controller.importBackup(jsonEncode([one.toJson(), two.toJson()])), 2);
    expect(controller.networks.every((n) => n.needsRejoin && n.pubkey == null), isTrue);
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async { nativeCalls++; return null; });
    await expectLater(FluxpeerChannel.startTunnel(controller.networks.first), throwsStateError);
    await controller.toggle();
    expect(controller.conn.value, FxConnState.error);
    expect(nativeCalls, 0);
  });
  test('invalid backup applies no partial membership entries', () {
    expect(() => controller.importBackup(jsonEncode([one.toJson(), {'id':'bad', 'controlUrl':'invalid'}])), throwsFormatException);
    expect(controller.networks, isEmpty);
  });
}
