import Foundation
import Darwin

func debugLog(_ message: String) { print(message) }

@main
struct InterfaceDiagnosticsTests {
    static func main() {
        typealias D = VPNInterfaceDiagnostics
        precondition(MemoryLayout<ifreq>.size == 32)
        precondition(MemoryLayout<ifreq>.offset(of: \.ifr_ifru) == 16)
        precondition(D.Getter.delegate.request == 0xc020699d)
        precondition(D.Getter.expensive.request == 0xc02069a0)
        precondition(D.Getter.constrained.request == 0xc02069cc)
        precondition(D.Reading.value(0).text == "0")
        precondition(D.Reading.unavailable(EPERM).text == "unknown(errno=1)")
        for getter in D.Getter.allCases {
            precondition(D.read(getter, interface: "") == .unavailable(EINVAL))
            precondition(D.read(getter, interface: String(repeating: "a", count: 16)) == .unavailable(EINVAL))
            precondition(D.read(getter, interface: "lo0\0extra") == .unavailable(EINVAL))
            if case .value = D.read(getter, interface: "zzmissing0") {
                fatalError("A missing interface was falsely reported as having measured flags")
            }
            let live = D.read(getter, interface: "lo0")
            // macOS kernel support is checked here; sandboxed iOS support needs the phone test.
            guard case .value = live else { fatalError("macOS loopback getter failed: \(live.text)") }
            print("Live getter \(getter): \(live.text)")
        }
        precondition(D.name(for: if_nametoindex("lo0")) == "lo0")
        precondition(D.name(for: UInt32.max) == nil)
        let lines = D.lines(phase: "test")
        precondition(!lines.isEmpty && lines.allSatisfy { $0.hasPrefix("[VPNPolicy] phase=test;") })
        D.log(phase: "test")
        print("Read-only interface diagnostic ABI, getters, invalid inputs and unknown/error distinction passed.")
    }
}
