import Foundation
import Darwin

let index = if_nametoindex("lo0")
precondition(index != 0)
let descriptor = socket(AF_INET, SOCK_STREAM, 0)
precondition(descriptor >= 0)
defer { close(descriptor) }
let binding = DeviceSocketBinding.Binding(interfaceName: "lo0", interfaceIndex: index,
                                         localIP: "127.0.0.1", targetIP: "127.0.0.1")
try binding.apply(to: descriptor)
var actualIndex: UInt32 = 0
var length = socklen_t(MemoryLayout<UInt32>.size)
precondition(getsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &actualIndex, &length) == 0)
precondition(actualIndex == index)
var local = sockaddr_in()
length = socklen_t(MemoryLayout<sockaddr_in>.size)
let result = withUnsafeMutablePointer(to: &local) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
}
precondition(result == 0)
var expected = in_addr()
precondition(inet_pton(AF_INET, "127.0.0.1", &expected) == 1)
precondition(local.sin_addr.s_addr == expected.s_addr)
let invalid = DeviceSocketBinding.Binding(interfaceName: "missing", interfaceIndex: UInt32.max,
                                         localIP: "127.0.0.1", targetIP: "127.0.0.1")
do {
    try invalid.apply(to: descriptor)
    fatalError("Missing interface silently succeeded")
} catch { }
DeviceSocketBinding.activateForTesting(binding, allowDirectHandshake: false)
precondition(!DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: "127.0.0.1", port: 49152))
DeviceSocketBinding.activateForTesting(nil, allowDirectHandshake: true)
precondition(!DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: "127.0.0.1", port: 49152))
DeviceSocketBinding.activateForTesting(binding, allowDirectHandshake: true)
precondition(DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: "127.0.0.1", port: 49152))
precondition(!DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: "10.7.0.1", port: 49152))
precondition(!DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: "127.0.0.1", port: 62078))
DeviceSocketBinding.deactivate()
precondition(DeviceSocketBinding.current(for: "10.7.0.1") == nil)
precondition(!DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: "127.0.0.1", port: 49152))
print("Swift socket interface/source binding and missing-interface rejection passed.")
