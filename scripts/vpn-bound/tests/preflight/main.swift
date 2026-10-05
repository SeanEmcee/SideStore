import Foundation
import Darwin

// Reserve a port without listening: a normal TCP preflight must fail here.
let reserved = socket(AF_INET, SOCK_STREAM, 0)
precondition(reserved >= 0)
defer { close(reserved) }
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = UInt16(49152).bigEndian
precondition(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(reserved, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
precondition(bound == 0, "Could not reserve the test's closed port: \(errno)")
let binding = DeviceSocketBinding.Binding(interfaceName: "lo0", interfaceIndex: if_nametoindex("lo0"),
                                         localIP: "127.0.0.1", targetIP: "127.0.0.1")
DeviceSocketBinding.activateForTesting(binding, allowDirectHandshake: false)
precondition(!NetworkUtils.testTCP(ip: "127.0.0.1", port: 49152))
DeviceSocketBinding.activateForTesting(binding, allowDirectHandshake: true)
precondition(NetworkUtils.testTCP(ip: "127.0.0.1", port: 49152))
let invalid = DeviceSocketBinding.Binding(interfaceName: "missing", interfaceIndex: UInt32.max,
                                         localIP: "127.0.0.1", targetIP: "127.0.0.1")
DeviceSocketBinding.activateForTesting(invalid, allowDirectHandshake: true)
precondition(!NetworkUtils.testTCP(ip: "127.0.0.1", port: 49152), "Binding errors must never be overridden")
DeviceSocketBinding.deactivate()
precondition(!NetworkUtils.testTCP(ip: "127.0.0.1", port: 49152))
print("Actual patched TCP probe: closed port rejected normally, diagnostic override scoped, binding failures rejected, cleanup restored normal probing.")
