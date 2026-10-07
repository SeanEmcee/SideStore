import Foundation
import Darwin

/// Read-only interface evidence. Never changes interface flags, delegation or radio state.
enum VPNInterfaceDiagnostics {
    // Pinned XNU sockio_private.h: SIOCGIFDELEGATE, SIOCGIFEXPENSIVE, SIOCGIFCONSTRAINED.
    // Their ifreq output is a UInt32 at the start of the public ifr_ifru union.
    enum Getter: UInt32, CaseIterable {
        case delegate = 157
        case expensive = 160
        case constrained = 204

        var request: UInt { UInt(0xc0000000 | (32 << 16) | (0x69 << 8) | rawValue) }
    }

    enum Reading: Equatable {
        case value(UInt32)
        case unavailable(Int32)

        var text: String {
            switch self {
            case .value(let value): return String(value)
            case .unavailable(let error): return "unknown(errno=\(error))"
            }
        }
    }

    static func read(_ getter: Getter, interface: String) -> Reading {
        let name = Array(interface.utf8)
        guard !name.isEmpty, name.count < Int(IFNAMSIZ), !name.contains(0) else {
            return .unavailable(EINVAL)
        }
        // Refuse an unfamiliar ABI rather than issue a request with an incorrect buffer.
        guard MemoryLayout<ifreq>.size == 32,
              MemoryLayout<ifreq>.offset(of: \.ifr_ifru) == 16 else {
            return .unavailable(ENOTSUP)
        }
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return .unavailable(errno) }
        defer { close(descriptor) }
        var request = ifreq()
        withUnsafeMutableBytes(of: &request) { buffer in
            buffer.copyBytes(from: name + [0])
        }
        let result = withUnsafeMutablePointer(to: &request) {
            ioctl(descriptor, getter.request, $0)
        }
        guard result == 0 else { return .unavailable(errno) }
        return .value(UInt32(bitPattern: request.ifr_ifru.ifru_intval))
    }

    static func name(for index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(index, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    static func lines(phase: String) -> [String] {
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            return ["[VPNPolicy] phase=\(phase); time=\(timestamp); enumeration=unknown(errno=\(errno))"]
        }
        defer { if let head { freeifaddrs(head) } }
        var cursor = head
        var tunnelNames = Set<String>()
        var wifiAddress = false
        var expected = in_addr()
        inet_pton(AF_INET, "10.7.0.2", &expected)
        while let entry = cursor {
            let info = entry.pointee
            if (info.ifa_flags & UInt32(IFF_UP)) != 0,
               let address = info.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                let interface = String(cString: info.ifa_name)
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if interface == "en0", ip != 0 { wifiAddress = true }
                if interface.hasPrefix("utun"), ip == expected.s_addr { tunnelNames.insert(interface) }
            }
            cursor = info.ifa_next
        }
        let prefix = "[VPNPolicy] phase=\(phase); time=\(timestamp); wifiIPv4=\(wifiAddress)"
        guard !tunnelNames.isEmpty else { return [prefix + "; expectedTunnel=absent"] }
        return tunnelNames.sorted().prefix(4).map { interface in
            let delegated = read(.delegate, interface: interface)
            var fields = "; interface=\(interface)#\(if_nametoindex(interface)); delegate=\(delegated.text)"
            fields += "; expensive=\(read(.expensive, interface: interface).text)"
            fields += "; constrained=\(read(.constrained, interface: interface).text)"
            if case .value(let index) = delegated, index != 0 {
                if let delegateName = name(for: index) {
                    fields += "; delegateName=\(delegateName)"
                    fields += "; delegateExpensive=\(read(.expensive, interface: delegateName).text)"
                    fields += "; delegateConstrained=\(read(.constrained, interface: delegateName).text)"
                } else {
                    fields += "; delegateName=unknown"
                }
            }
            return prefix + fields
        }
    }

    static func log(phase: String) {
        for line in lines(phase: phase) { debugLog(line) }
    }
}
