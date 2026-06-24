// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxpeer/models/models.dart';

void main() {
  test('network settings round-trip through json', () {
    const network = FxNetwork(
      id: 'net-1',
      name: 'home',
      controlUrl: 'https://ctrl.example',
      overlayV4: '100.72.16.5',
      deviceId: 'dev-1',
      pubkey: 'pk-1',
      dns: ['1.1.1.1'],
      exitNode: true,
      excludeRoutes: ['192.168.0.0/16'],
      transportProtocol: 'anytls',
    );

    final roundTrip = FxNetwork.fromJson(network.toJson());

    expect(roundTrip.id, network.id);
    expect(roundTrip.name, network.name);
    expect(roundTrip.controlUrl, network.controlUrl);
    expect(roundTrip.overlayV4, network.overlayV4);
    expect(roundTrip.deviceId, network.deviceId);
    expect(roundTrip.pubkey, network.pubkey);
    expect(roundTrip.dns, network.dns);
    expect(roundTrip.exitNode, isTrue);
    expect(roundTrip.excludeRoutes, network.excludeRoutes);
    expect(roundTrip.transportProtocol, 'anytls');
    expect(network.toJson()['user_transport'], 'anytls');
  });
}
