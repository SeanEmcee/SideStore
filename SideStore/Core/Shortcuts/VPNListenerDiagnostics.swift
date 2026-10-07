import Foundation
import Darwin

/// Read-only evidence about device-service TCP listeners, never a readiness check.
/// Private ABI availability on sandboxed iOS needs proper testing on the phone.
enum VPNListenerDiagnostics {
    struct Listener: Equatable {
        let port: UInt16
        let pid: UInt32
        let accepting: Bool
        let noCellular: Bool
        let noExpensive: Bool
        let noConstrained: Bool
        let binding: String
    }

    enum Result: Equatable {
        case snapshot([Listener], stable: Bool)
        case unavailable(Int32)
        case unfamiliarFormat
        case tooLarge
    }

    static let maximumBytes = 2 * 1024 * 1024
    static let servicePorts: Set<UInt16> = [49152, 62078]

    static func read(ports: Set<UInt16> = servicePorts) -> Result {
        // No writes, new value, raw dump, or persistent copy of other sockets.
        let key = "net.inet.tcp.pcblist_n"
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return .unavailable(errno) }
        guard size > 0, size <= maximumBytes else { return .tooLarge }
        for _ in 0..<2 {
            var bytes = [UInt8](repeating: 0, count: size)
            var actual = size
            let status = bytes.withUnsafeMutableBytes {
                sysctlbyname(key, $0.baseAddress, &actual, nil, 0)
            }
            if status == 0 {
                guard actual <= bytes.count else { return .unfamiliarFormat }
                return parse(Array(bytes.prefix(actual)), ports: ports)
            }
            let error = errno
            guard error == ENOMEM else { return .unavailable(error) }
            size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return .unavailable(errno) }
            guard size > 0, size <= maximumBytes else { return .tooLarge }
        }
        return .unavailable(ENOMEM)
    }

    static func parse(_ bytes: [UInt8], ports: Set<UInt16> = servicePorts) -> Result {
        // Pinned XNU f6217f89: pack(4) xinpcb_n and xsocket_n are 104 bytes.
        // xinpgen is 24 bytes. Exported records are padded to 8-byte boundaries.
        // Refuse changed layouts; never reinterpret a truncated buffer as no listener.
        guard bytes.count >= 48, bytes.count <= maximumBytes else { return .unfamiliarFormat }
        func u32(_ at: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(bytes[at + $1]) << ($1 * 8)) }
        }
        func sameGeneration(_ first: Int, _ last: Int) -> Bool {
            bytes[first + 4..<first + 24].elementsEqual(bytes[last + 4..<last + 24])
        }
        guard u32(0) == 24 else { return .unfamiliarFormat }
        var cursor = 24
        var listeners: [Listener] = []
        var pending: (port: UInt16, flags: UInt32, flags2: UInt32, binding: String)?
        var waitingForSocket = false
        while cursor <= bytes.count - 8 {
            let length = Int(u32(cursor))
            if length == 24, cursor == bytes.count - 24 {
                guard !waitingForSocket else { return .unfamiliarFormat }
                return .snapshot(listeners, stable: sameGeneration(0, cursor))
            }
            guard length >= 8, length <= bytes.count - cursor else { return .unfamiliarFormat }
            let padded = (length + 7) & ~7
            guard padded <= bytes.count - cursor else { return .unfamiliarFormat }
            let kind = u32(cursor + 4)
            if waitingForSocket, kind != 1 { return .unfamiliarFormat }
            if kind == 16 { // XSO_INPCB
                guard length == 104 else { return .unfamiliarFormat }
                waitingForSocket = true
                pending = nil
                let foreignPort = UInt16(bytes[cursor + 16]) << 8 | UInt16(bytes[cursor + 17])
                let localPort = UInt16(bytes[cursor + 18]) << 8 | UInt16(bytes[cursor + 19])
                if foreignPort == 0, ports.contains(localPort) {
                    let vflag = bytes[cursor + 44]
                    let address = Array(bytes[cursor + 64..<cursor + 80])
                    let binding: String
                    if address.allSatisfy({ $0 == 0 }) {
                        binding = "wildcard"
                    } else if vflag & 1 != 0 {
                        binding = address.suffix(4).map { String($0) }.joined(separator: ".")
                    } else if vflag & 2 != 0 {
                        binding = "specific-IPv6"
                    } else { return .unfamiliarFormat }
                    pending = (localPort, u32(cursor + 36), u32(cursor + 100), binding)
                }
            } else if kind == 1 { // XSO_SOCKET immediately follows its INPCB.
                guard waitingForSocket, length == 104 else { return .unfamiliarFormat }
                waitingForSocket = false
                if let entry = pending {
                    guard u32(cursor + 36) == UInt32(IPPROTO_TCP) else { return .unfamiliarFormat }
                    if listeners.count < 8 {
                        listeners.append(Listener(port: entry.port, pid: u32(cursor + 68),
                            accepting: u32(cursor + 20) & UInt32(SO_ACCEPTCONN) != 0,
                            noCellular: entry.flags & 0x20000000 != 0,
                            noExpensive: entry.flags2 & 0x8 != 0,
                            noConstrained: entry.flags2 & 0x800 != 0, binding: entry.binding))
                    }
                }
                pending = nil
            }
            cursor += padded
        }
        return .unfamiliarFormat
    }

    static func log(phase: String) {
        let prefix = "[VPNListener] phase=\(phase); time=\(String(format: "%.3f", Date().timeIntervalSince1970))"
        switch read() {
        case .unavailable(let error): debugLog(prefix + "; query=unknown(errno=\(error))")
        case .unfamiliarFormat: debugLog(prefix + "; query=unknown(unfamiliar-format)")
        case .tooLarge: debugLog(prefix + "; query=unknown(size-limit)")
        case .snapshot(let listeners, let stable):
            debugLog(prefix + "; exportedServiceRecords=\(listeners.count); generationStable=\(stable); absenceIsInconclusive=true")
            for listener in listeners {
                debugLog(prefix + "; port=\(listener.port); pid=\(listener.pid); accepting=\(listener.accepting); binding=\(listener.binding); noCellular=\(listener.noCellular); noExpensive=\(listener.noExpensive); noConstrained=\(listener.noConstrained)")
            }
        }
    }
}
