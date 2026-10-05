import Foundation
import Darwin

/// Scoped to prepared installation. Ordinary refresh never activates this policy.
public enum DeviceSocketBinding {
    public struct Binding: Sendable, Equatable {
        public let interfaceName: String
        public let interfaceIndex: UInt32
        public let localIP: String
        public let targetIP: String

        public func apply(to descriptor: Int32) throws {
            // IP_BOUND_IF prevents this socket from falling back to a cellular interface.
            var index = interfaceIndex
            guard setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index,
                             socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, localIP, &local.sin_addr) == 1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
            let result = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var binding: Binding?
    }
    private static let state = State()

    public static func current(for targetIP: String) -> Binding? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.binding?.targetIP == targetIP ? state.binding : nil
    }

    /// Find the intended tunnel by its address, never by a hardcoded utun number.
    @discardableResult
    public static func activateIfAvailable() throws -> Binding? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { if let head = head { freeifaddrs(head) } }
        var cursor = head
        var names = Set<String>()
        var expected = in_addr()
        inet_pton(AF_INET, "10.7.0.2", &expected)
        while let entry = cursor {
            let info = entry.pointee
            let name = String(cString: info.ifa_name)
            if name.hasPrefix("utun"), (info.ifa_flags & UInt32(IFF_UP)) != 0,
               let address = info.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                let matches = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr == expected.s_addr
                }
                if matches { names.insert(name) }
            }
            cursor = info.ifa_next
        }
        guard names.count <= 1 else {
            throw NSError(domain: "VPNBoundTransport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Multiple VPN interfaces have 10.7.0.2; the device route is ambiguous."])
        }
        let binding = names.first.flatMap { name -> Binding? in
            let index = if_nametoindex(name)
            return index == 0 ? nil : Binding(interfaceName: name, interfaceIndex: index,
                                            localIP: "10.7.0.2", targetIP: "10.7.0.1")
        }
        state.lock.lock()
        state.binding = binding
        state.lock.unlock()
        return binding
    }

    public static func deactivate() {
        state.lock.lock()
        state.binding = nil
        state.lock.unlock()
    }
}
