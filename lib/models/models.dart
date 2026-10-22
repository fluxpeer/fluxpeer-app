// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

/// Connection lifecycle state driving the ConnectRing + tunnel.
enum FxConnState {
  disconnected,
  authorizing,
  connecting,
  connected,
  disconnecting,
  error
}

/// How a peer session is carried.
enum FxTransport { udpDirect, relay, connecting, idle }

FxConnState connStateFromName(String? s) => FxConnState.values.firstWhere(
      (e) => e.name == s,
      orElse: () => FxConnState.disconnected,
    );

FxTransport transportFromName(String? s) => FxTransport.values.firstWhere(
      (e) => e.name == s,
      orElse: () => FxTransport.idle,
    );

/// A joined mesh network — persisted locally (mirrors a control "network").
class FxNetwork {
  final String id;
  final String name;
  final String controlUrl;
  final bool needsRejoin;
  final String? overlayV4;
  final String? deviceId;
  final String? pubkey;
  // local settings (applied on connect)
  final int mtu;
  final bool mtuExplicit;
  final List<String> dns;
  final bool exitNode;
  final List<String> excludeRoutes;
  // Connection mode. 'auto' = use the gateway's default transport (UDP-direct).
  // 'anytls' / 'tcp-bond' = force that transport (anti-censorship / lossy links).
  // Mobile uses ONE fixed transport (no desktop-style auto-fallback ladder).
  final String transportProtocol;

  const FxNetwork({
    required this.id,
    required this.name,
    required this.controlUrl,
    this.needsRejoin = false,
    this.overlayV4,
    this.deviceId,
    this.pubkey,
    this.mtu = 1380,
    this.mtuExplicit = false,
    this.dns = const [],
    this.exitNode = false,
    this.excludeRoutes = const [],
    this.transportProtocol = 'auto',
  });

  /// Origin + server network id + enrolled device id is the local identity.
  String get key => membershipKey(controlUrl, id, deviceId ?? '');

  Map<String, dynamic> toBackup() => {
    'id': id, 'name': name, 'controlUrl': controlUrl, 'deviceId': deviceId,
    'mtu': mtu, 'mtuExplicit': mtuExplicit, 'dns': dns, 'exitNode': exitNode,
    'excludeRoutes': excludeRoutes, 'transportProtocol': transportProtocol,
    'needsRejoin': true,
  };

  FxNetwork copyWith({
    String? name,
    String? overlayV4,
    int? mtu,
    bool? mtuExplicit,
    List<String>? dns,
    bool? exitNode,
    List<String>? excludeRoutes,
    String? transportProtocol,
  }) =>
      FxNetwork(
        id: id,
        name: name ?? this.name,
        controlUrl: controlUrl,
        needsRejoin: needsRejoin,
        overlayV4: overlayV4 ?? this.overlayV4,
        deviceId: deviceId,
        pubkey: pubkey,
        mtu: mtu ?? this.mtu,
        mtuExplicit: mtuExplicit ?? this.mtuExplicit,
        dns: dns ?? this.dns,
        exitNode: exitNode ?? this.exitNode,
        excludeRoutes: excludeRoutes ?? this.excludeRoutes,
        transportProtocol: transportProtocol ?? this.transportProtocol,
      );

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'name': name,
      'controlUrl': controlUrl,
      'needsRejoin': needsRejoin,
      'overlayV4': overlayV4,
      'deviceId': deviceId,
      'pubkey': pubkey,
      'mtu': mtu,
      'mtuExplicit': mtuExplicit,
      'dns': dns,
      'exitNode': exitNode,
      'excludeRoutes': excludeRoutes,
      'transportProtocol': transportProtocol,
    };
    // Only force a transport when the user picked a non-auto mode; native then
    // prefers `user_transport` over the gateway-advertised default.
    if (transportProtocol != 'auto') m['user_transport'] = transportProtocol;
    return m;
  }

  factory FxNetwork.fromJson(Map<String, dynamic> j) => FxNetwork(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'network',
        controlUrl: j['controlUrl'] as String? ?? '',
        needsRejoin: j['needsRejoin'] as bool? ?? false,
        overlayV4: j['overlayV4'] as String?,
        deviceId: j['deviceId'] as String?,
        pubkey: j['pubkey'] as String?,
        mtu: (j['mtu'] as num?)?.toInt() ?? 1380,
        mtuExplicit: j['mtuExplicit'] as bool? ?? (j['mtu'] != null && j['mtu'] != 1380),
        dns: (j['dns'] as List?)?.cast<String>() ?? const [],
        exitNode: j['exitNode'] as bool? ?? false,
        excludeRoutes:
            (j['excludeRoutes'] as List?)?.cast<String>() ?? const [],
        transportProtocol: j['transportProtocol'] as String? ?? 'auto',
      );
}

/// A peer in the mesh (from FFI status).
class FxPeer {
  final String name;
  final String pubkey;
  final String? endpoint;
  final FxTransport transport;
  final int? lastHandshakeMs;
  final int rxBytes;
  final int txBytes;
  final int? rttMs;

  const FxPeer({
    required this.name,
    required this.pubkey,
    this.endpoint,
    this.transport = FxTransport.idle,
    this.lastHandshakeMs,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rttMs,
  });

  factory FxPeer.fromJson(Map<String, dynamic> j) => FxPeer(
        name: j['name'] as String? ?? 'peer',
        pubkey: j['pubkey'] as String? ?? '',
        endpoint: j['endpoint'] as String?,
        transport: transportFromName(j['transport'] as String?),
        lastHandshakeMs: (j['lastHandshakeMs'] as num?)?.toInt(),
        rxBytes: (j['rxBytes'] as num?)?.toInt() ?? 0,
        txBytes: (j['txBytes'] as num?)?.toInt() ?? 0,
        rttMs: (j['rttMs'] as num?)?.toInt(),
      );
}

/// Snapshot of the running tunnel — the source of truth for cold-start sync
/// (the tunnel runs in the OS NE/VpnService process, not the Flutter app process).
class FxStateSnapshot {
  final FxConnState state;
  final String? networkId;
  final String? overlayV4;
  final int? connectedAtMs;
  final String? warning;
  final List<FxPeer> peers;

  const FxStateSnapshot({
    this.state = FxConnState.disconnected,
    this.networkId,
    this.overlayV4,
    this.connectedAtMs,
    this.warning,
    this.peers = const [],
  });

  factory FxStateSnapshot.fromJson(Map<String, dynamic> j) => FxStateSnapshot(
        state: connStateFromName(j['state'] as String?),
        networkId: j['networkId'] as String?,
        overlayV4: j['overlayV4'] as String?,
        connectedAtMs: (j['connectedAtMs'] as num?)?.toInt(),
        warning: j['warning'] as String?,
        peers: (j['peers'] as List?)
                ?.map((e) => FxPeer.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
      );
}

String membershipKey(String control, String network, String device) {
  final uri = Uri.parse(control);
  if (network.isEmpty || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('Invalid control origin');
  }
  final origin = uri.origin.toLowerCase();
  return 'v2.${[origin, network, device].map((part) => base64Url.encode(utf8.encode(part)).replaceAll('=', '')).join('.')}';
}
