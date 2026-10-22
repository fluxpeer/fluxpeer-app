// SPDX-License-Identifier: AGPL-3.0-or-later
import NetworkExtension
import Darwin

/// Public packetFlow API bridged to the node's iOS packet-information framing.
/// All methods and callbacks are serialized on the main queue.
final class PacketBridge {
    private let flow: NEPacketTunnelFlow
    private let socket: Int32
    private var engine: Int32
    private var source: DispatchSourceRead?
    private var reading = false
    private var closed = false
    var blockIPv6 = false
    var failed: ((Error) -> Void)?
    init(_ flow: NEPacketTunnelFlow) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { throw TunnelPolicy.error("packet socketpair failed") }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(pair[0]); Darwin.close(pair[1]); throw TunnelPolicy.error("packet socket setup failed") }
        self.flow = flow; socket = pair[0]; engine = pair[1]
    }
    func startEngine(_ config: String, generation: UInt64) throws {
        defer { Darwin.close(engine); engine = -1 }
        _ = try FluxpeerNative.unwrap(FluxpeerNative.start(config, fd: engine, generation: generation))
    }
    func startPackets() {
        guard !reading && !closed else { return }; reading = true
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        let fd = socket
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.drain() }
        self.source = source; source.resume(); readPackets()
    }
    private func readPackets() {
        guard !closed else { return }
        flow.readPackets { [weak self] packets, families in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                for (packet, family) in zip(packets, families) {
                    guard let frame = PacketFraming.wrap(packet, family: family.uint32Value, blockIPv6: self.blockIPv6) else { continue }
                    let sent = frame.withUnsafeBytes { Darwin.send(self.socket, $0.baseAddress, $0.count, 0) }
                    if sent < 0 && errno != EAGAIN && errno != ENOBUFS { self.failed?(TunnelPolicy.error("packet write failed")); return }
                }
                self.readPackets()
            }
        }
    }
    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 65539)
        for _ in 0..<32 {
            let count = Darwin.recv(socket, &bytes, bytes.count, 0)
            if count < 0 { if errno != EAGAIN { failed?(TunnelPolicy.error("packet read failed")) }; return }
            guard count > 4 else { continue }
            guard let (packet, family) = PacketFraming.unwrap(Data(bytes.prefix(count)), blockIPv6: blockIPv6) else { continue }
            if !flow.writePackets([packet], withProtocols: [family]) { failed?(TunnelPolicy.error("packet delivery failed")); return }
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        if engine >= 0 { Darwin.close(engine); engine = -1 }
        if let source { source.cancel(); self.source = nil } else { Darwin.close(socket) }
    }
    deinit { close() }
}
