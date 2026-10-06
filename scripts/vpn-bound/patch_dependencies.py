"""Apply narrowly scoped patches to the exact dependency versions used by this fork.

Generated dependency changes stay in the CI checkout; the original submodule pins
and the existing unbound FFI entry point are preserved.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

IDEVICE_REVISION = "3e55c8486b2057e40c1f74aaaa1155c82341cf76"
MINIMUXER_REVISION = "12be70dc2627307a16bfd2dc7a009080d5bec909"
TEMPLATES = Path(__file__).resolve().parent


def revision(path, expected):
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != expected:
        raise RuntimeError(f"Refusing to patch {path}: expected {expected}, got {actual}")


def replace(path, before, after, count=1):
    text = path.read_text(encoding="utf-8")
    if text.count(before) != count:
        raise RuntimeError(f"Patch anchor changed in {path}: {before[:80]!r}")
    path.write_text(text.replace(before, after), encoding="utf-8", newline="\n")


def patch_idevice(root):
    revision(root, IDEVICE_REVISION)
    (root / "ffi/src/vpn_binding.rs").write_text(
        (TEMPLATES / "vpn_binding.rs").read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    replace(root / "ffi/src/lib.rs", "mod errors;", 'mod errors;\n#[cfg(feature = "remote_pairing")]\nmod vpn_binding;')
    path = root / "ffi/src/tunnel_provider.rs"
    replace(path, "    connect_addr: std::net::SocketAddr,\n)",
            "    connect_addr: std::net::SocketAddr,\n    binding: Option<crate::vpn_binding::Binding>,\n)")
    replace(path, "run_global_timeout(|| tokio::net::TcpStream::connect(tunnel_addr))",
            'run_global_timeout(|| crate::vpn_binding::connect(tunnel_addr, binding, "device-tunnel"))')
    replace(path, '.map_err(|e| IdeviceError::InternalError(format!("TLS tunnel: {e}")))?;',
            '.map_err(|e| crate::vpn_binding::connection_error(e, binding, "device-tunnel", tunnel_addr))?;')
    # RemoteXPC continues to use its original unbound behavior.
    replace(path, "finish_tunnel(&mut rpc, socket_addr).await", "finish_tunnel(&mut rpc, socket_addr, None).await", count=2)
    text = path.read_text(encoding="utf-8")
    start = text.index('#[unsafe(no_mangle)]\npub unsafe extern "C" fn tunnel_create_rppairing_with_options(')
    end = text.index("/// Pairs with a device over the network via raw RPPairing", start)
    original = text[start:end]
    patched = original.replace('#[unsafe(no_mangle)]\npub unsafe extern "C" fn tunnel_create_rppairing_with_options(',
                               'unsafe fn tunnel_create_rppairing_impl(')
    patched = patched.replace("    out_handshake: *mut *mut RsdHandshakeHandle,\n)",
                              "    out_handshake: *mut *mut RsdHandshakeHandle,\n    binding: Option<crate::vpn_binding::Binding>,\n)")
    patched = patched.replace("run_global_timeout(|| tokio::net::TcpStream::connect(socket_addr))",
                              'run_global_timeout(|| crate::vpn_binding::connect(socket_addr, binding, "rppairing"))')
    connect_error = '.map_err(|e| IdeviceError::InternalError(format!("connect: {e}")))?;'
    if patched.count(connect_error) != 1:
        raise RuntimeError("Remote Pairing connect error anchor changed")
    patched = patched.replace(connect_error,
                              '.map_err(|e| crate::vpn_binding::connection_error(e, binding, "rppairing", socket_addr))?;')
    patched = patched.replace("finish_tunnel(&mut rpc, socket_addr, None).await",
                              "finish_tunnel(&mut rpc, socket_addr, binding).await")
    signature = original[original.index("    addr:"):original.index(") -> *mut IdeviceFfiError")]
    args = "addr, addr_len, hostname, pairing_file, pair_if_needed, pin_callback, pin_context, out_adapter, out_handshake"
    wrappers = f'''#[unsafe(no_mangle)]
pub unsafe extern "C" fn tunnel_create_rppairing_with_options(
{signature}) -> *mut IdeviceFfiError {{
    unsafe {{ tunnel_create_rppairing_impl({args}, None) }}
}}

/// Same protocol and pairing file, with both native TCP sockets scoped to a VPN.
/// # Safety
/// Same pointer requirements as the unbound function; local_ip must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tunnel_create_rppairing_with_options_bound(
{signature}    local_ip: *const c_char,
    interface_index: u32,
) -> *mut IdeviceFfiError {{
    if local_ip.is_null() || interface_index == 0 {{
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }}
    let local_ip = match unsafe {{ CStr::from_ptr(local_ip) }}.to_str().ok()
        .and_then(|s| s.parse::<std::net::Ipv4Addr>().ok()) {{
        Some(ip) => ip,
        None => return ffi_err!(IdeviceError::FfiInvalidArg),
    }};
    let binding = crate::vpn_binding::Binding {{ local_ip, interface_index }};
    unsafe {{ tunnel_create_rppairing_impl({args}, Some(binding)) }}
}}

'''
    path.write_text(text[:start] + wrappers + patched + text[end:], encoding="utf-8", newline="\n")


def patch_minimuxer(root, framework):
    revision(root, MINIMUXER_REVISION)
    (root / "Common/DeviceSocketBinding.swift").write_text(
        (TEMPLATES / "DeviceSocketBinding.swift").read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    replace(root / "Common/Package.swift", '                "NetworkUtils.swift",',
            '                "NetworkUtils.swift",\n                "DeviceSocketBinding.swift",')
    replace(root / "Common/NetworkUtils.swift", "        defer { close(fd) }", '''        defer { close(fd) }
        if let binding = DeviceSocketBinding.current(for: ip) {
            do {
                try binding.apply(to: fd)
                debugLog("[VPNBound] probe: interface=\\(binding.interfaceName), source=\\(binding.localIP), target=\\(ip):\\(port)")
                if DeviceSocketBinding.shouldSkipPreliminaryProbe(ip: ip, port: port) {
                    debugLog("[VPNBound] diagnostic: TCP preflight skipped; real pairing handshake required for \\(ip):\\(port)")
                    return true
                }
            } catch {
                debugLog("[VPNBound] probe binding failed: \\(error)")
                return false
            }
        }''')
    path = root / "DeviceGateway/idevice/IdeviceGateway.swift"
    replace(path, "    private var handshake: OpaquePointer? = nil",
            "    private var handshake: OpaquePointer? = nil\n    private var connectionBinding: DeviceSocketBinding.Binding? = nil")
    replace(path, "    public override func invalidateConnection() {",
            "    public override func invalidateConnection() {\n        connectionBinding = nil")
    replace(path, "    private func ensureRPConnection() throws {", '''    private func ensureRPConnection() throws {
        let binding = deviceEndpointIp.flatMap { DeviceSocketBinding.current(for: $0) }
        // Do not reuse a tunnel created under a different interface policy.
        if connectionBinding != binding { invalidateConnection() }''')
    replace(path, '        debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing succeeded,',
            '        connectionBinding = binding\n        debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing succeeded,')
    old = '''                err = tunnel_create_rppairing_with_options(
                    sockaddrPtr,
                    sockaddrLen,
                    hostPtr,
                    pairingFile,
                    false,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )'''
    new = '''                if let binding = binding {
                    debugLog("[VPNBound] gateway: interface=\\(binding.interfaceName), source=\\(binding.localIP), target=\\(deviceEndpointIp):\\(rpPort)")
                    binding.localIP.withCString { localPtr in
                        err = tunnel_create_rppairing_with_options_bound(
                            sockaddrPtr, sockaddrLen, hostPtr, pairingFile, false,
                            nil, nil, &adapter, &handshake, localPtr, binding.interfaceIndex)
                    }
                } else {
''' + "\n".join("    " + line for line in old.splitlines()) + '''
                }'''
    replace(path, old, new)
    path = root / "DeviceGateway/Package.swift"
    text = path.read_text(encoding="utf-8")
    start = text.index('         .binaryTarget(\n             name: "IDevice",')
    end = text.index("         ),", start) + len("         ),")
    relative_framework = Path(os.path.relpath(framework.resolve(), path.parent.resolve())).as_posix()
    text = text[:start] + f'         .binaryTarget(name: "IDevice", path: {json.dumps(relative_framework)}),' + text[end:]
    path.write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--idevice", type=Path, required=True)
    parser.add_argument("--minimuxer", type=Path, required=True)
    options = parser.parse_args()
    patch_idevice(options.idevice)
    patch_minimuxer(options.minimuxer, options.idevice / "swift/IDevice.xcframework")
    print("Pinned dependencies patched: probe, Remote Pairing, and subsequent device tunnel.")
