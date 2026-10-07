import Foundation
import Darwin

func debugLog(_ message: String) { print(message) }

@main
struct ListenerDiagnosticTests {
    typealias D = VPNListenerDiagnostics

    static func fixture(flags: UInt32 = 0, flags2: UInt32 = 0, foreignPort: UInt16 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 24 + 104 + 104 + 24)
        func put(_ at: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        put(0, 24); put(4, 1); put(bytes.count - 24, 24); put(bytes.count - 20, 1)
        put(24, 104); put(28, 16)
        bytes[24 + 16] = UInt8(truncatingIfNeeded: foreignPort >> 8)
        bytes[24 + 17] = UInt8(truncatingIfNeeded: foreignPort)
        bytes[24 + 18] = 0xc0; bytes[24 + 19] = 0 // 49152, network byte order
        put(24 + 36, flags); bytes[24 + 44] = 1
        put(24 + 100, flags2)
        put(128, 104); put(132, 1)
        put(128 + 20, UInt32(SO_ACCEPTCONN)); put(128 + 36, UInt32(IPPROTO_TCP))
        put(128 + 68, 123)
        return bytes
    }

    static func main() {
        let listener = D.Listener(port: 49152, pid: 123, accepting: true,
            noCellular: true, noExpensive: true, noConstrained: true, binding: "wildcard")
        let flags = fixture(flags: 0x20000000, flags2: 0x808)
        precondition(D.parse(flags) == .snapshot([listener], stable: true))
        precondition(D.parse(fixture(foreignPort: 1234)) == .snapshot([], stable: true))
        precondition(D.parse(flags, ports: [62078]) == .snapshot([], stable: true))
        var changing = flags
        changing[changing.count - 20] = 2
        precondition(D.parse(changing) == .snapshot([listener], stable: false))
        var bound = flags
        bound[24 + 76] = 10; bound[24 + 77] = 7; bound[24 + 79] = 2
        if case .snapshot(let rows, _) = D.parse(bound) { precondition(rows.first?.binding == "10.7.0.2") }
        else { fatalError("Specific binding rejected") }
        for count in 0..<flags.count {
            precondition(D.parse(Array(flags.prefix(count))) == .unfamiliarFormat)
        }
        for offset in [0, 24, 128, flags.count - 24] {
            var changed = flags
            changed[offset] = 0xff
            precondition(D.parse(changed) == .unfamiliarFormat)
        }
        var mismatched = flags
        mismatched[132] = 16
        precondition(D.parse(mismatched) == .unfamiliarFormat)
        precondition(D.Result.unavailable(EPERM) != .snapshot([], stable: true))

        // Verify offsets/port endianness against a real macOS kernel export, not only fixtures.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let boundStatus = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(boundStatus == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        precondition(nameStatus == 0)
        let port = UInt16(bigEndian: address.sin_port)
        func ownListener() -> D.Listener {
            guard case .snapshot(let rows, _) = D.read(ports: [port]),
                  let row = rows.first(where: { $0.pid == UInt32(getpid()) && $0.accepting }) else {
                fatalError("Could not identify this process's live TCP listener in kernel export: \(D.read(ports: [port]))")
            }
            return row
        }
        precondition(ownListener().port == port && !ownListener().noCellular)
        var excluded: Int32 = 1
        precondition(setsockopt(fd, IPPROTO_IP, 6969, &excluded, socklen_t(MemoryLayout<Int32>.size)) == 0)
        precondition(ownListener().noCellular)
        D.log(phase: "test")
        print("TCP export parser bounds, identities, restriction bits, malformed/unstable snapshots and live listener exclusion passed.")
    }
}
