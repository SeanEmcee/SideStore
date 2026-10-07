use std::net::{Ipv4Addr, SocketAddr};

#[derive(Clone, Copy)]
pub(crate) struct Binding {
    pub(crate) local_ip: Ipv4Addr,
    pub(crate) interface_index: u32,
}

pub(crate) async fn connect(
    target: SocketAddr,
    binding: Option<Binding>,
    stage: &str,
) -> std::io::Result<tokio::net::TcpStream> {
    let Some(binding) = binding else {
        return tokio::net::TcpStream::connect(target).await;
    };
    #[cfg(target_vendor = "apple")]
    {
        use std::os::fd::AsRawFd;
        if !target.is_ipv4() || binding.interface_index == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "invalid VPN socket binding",
            ));
        }
        let socket = tokio::net::TcpSocket::new_v4()?;
        let index = binding.interface_index;
        // Public Darwin IP_BOUND_IF. A vanished interface fails; there is no unbound retry.
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_IP,
                libc::IP_BOUND_IF,
                &index as *const u32 as *const libc::c_void,
                std::mem::size_of::<u32>() as libc::socklen_t,
            )
        };
        if result != 0 {
            return Err(std::io::Error::last_os_error());
        }
        socket.bind(SocketAddr::new(binding.local_ip.into(), 0))?;
        eprintln!(
            "[VPNBound] {stage}: interface={index}, source={}, target={target}",
            binding.local_ip
        );
        let started = std::time::Instant::now();
        let stream = match socket.connect(target).await {
            Ok(stream) => stream,
            Err(error) => {
                eprintln!(
                    "[VPNBound] {stage}: TCP connect failed after {}ms: kind={:?}, os_code={:?}, message={error}",
                    started.elapsed().as_millis(),
                    error.kind(),
                    error.raw_os_error()
                );
                // Needs phone testing: reflection replies may conflict with IP_BOUND_IF.
                // Retain the VPN source and endpoint; only release interface pinning.
                if !should_retry_with_route(target, binding, stage, &error) {
                    return Err(error);
                }
                eprintln!(
                    "[VPNBound] {stage}: retrying with VPN source and system route; target={target}; source={}",
                    binding.local_ip
                );
                let socket = source_bound_socket(binding)?;
                match socket.connect(target).await {
                    Ok(stream) => stream,
                    Err(retry_error) => {
                        eprintln!(
                            "[VPNBound] {stage}: route-selected retry failed: {retry_error}; original scoped error: {error}"
                        );
                        // The bg.24 phone capture proved denying cellular blocks this route.
                        // Keep the real receiving-side refusal for provider recovery diagnostics.
                        return Err(retry_error);
                    }
                }
            }
        };
        eprintln!(
            "[VPNBound] {stage}: connected from {}",
            stream.local_addr()?
        );
        Ok(stream)
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (binding, stage);
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "VPN-bound transport requires Darwin",
        ))
    }
}

fn should_retry_with_route(
    target: SocketAddr,
    binding: Binding,
    stage: &str,
    error: &std::io::Error,
) -> bool {
    target.ip() == std::net::IpAddr::V4(Ipv4Addr::new(10, 7, 0, 1))
        && binding.local_ip == Ipv4Addr::new(10, 7, 0, 2)
        && matches!(stage, "rppairing" | "device-tunnel")
        && matches!(
            error.kind(),
            std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::ConnectionReset
        )
}

#[cfg(target_vendor = "apple")]
fn source_bound_socket(binding: Binding) -> std::io::Result<tokio::net::TcpSocket> {
    // Do not remove source binding or retry socket setup failures as unbound traffic.
    let socket = tokio::net::TcpSocket::new_v4()?;
    socket.bind(SocketAddr::new(binding.local_ip.into(), 0))?;
    Ok(socket)
}

#[cfg(all(test, target_vendor = "apple"))]
fn cellular_denied_socket(binding: Binding) -> std::io::Result<tokio::net::TcpSocket> {
    use std::os::fd::AsRawFd;
    // Apple XNU bsd/netinet/in_private.h: internal option, not a stable SDK API.
    // ip_output.c sets SO_RESTRICT_DENY_CELLULAR; getsockopt reads INP_NO_CELLULAR.
    // Fail explicitly if this OS does not support or retain it; never pretend success.
    const IP_NO_IFT_CELLULAR: libc::c_int = 6969;
    let socket = source_bound_socket(binding)?;
    let enabled: libc::c_int = 1;
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            IP_NO_IFT_CELLULAR,
            &enabled as *const _ as *const libc::c_void,
            std::mem::size_of_val(&enabled) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut measured: libc::c_int = 0;
    let mut length = std::mem::size_of_val(&measured) as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            IP_NO_IFT_CELLULAR,
            &mut measured as *mut _ as *mut libc::c_void,
            &mut length,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if measured != 1 || length as usize != std::mem::size_of_val(&measured) {
        return Err(std::io::Error::other(
            "device socket did not retain cellular restriction",
        ));
    }
    eprintln!(
        "[VPNBound] cellular-denied socket verified: IP_NO_IFT_CELLULAR=1; source={}; system route",
        binding.local_ip
    );
    Ok(socket)
}

// Preserve the OS cause through FFI instead of IdeviceError::Socket's generic Display.
pub(crate) fn connection_error(
    error: idevice::IdeviceError,
    binding: Option<Binding>,
    stage: &str,
    target: SocketAddr,
) -> idevice::IdeviceError {
    let Some(binding) = binding else {
        let prefix = if stage == "device-tunnel" {
            "TLS tunnel"
        } else {
            "connect"
        };
        return idevice::IdeviceError::InternalError(format!("{prefix}: {error}"));
    };
    let detail = match &error {
        idevice::IdeviceError::Socket(cause) => format!(
            "kind={:?}, os_code={:?}, message={cause}",
            cause.kind(),
            cause.raw_os_error()
        ),
        other => format!("{other:?}"),
    };
    let message = format!(
        "{stage} TCP connect failed: {detail}; target={target}; source={}; interface={}",
        binding.local_ip, binding.interface_index
    );
    eprintln!("[VPNBound] {message}");
    idevice::IdeviceError::InternalError(message)
}

#[cfg(all(test, target_vendor = "apple"))]
mod tests {
    use super::*;

    fn ffi_message(error: idevice::IdeviceError) -> String {
        let ffi = crate::ffi_err!(error);
        let message = unsafe { std::ffi::CStr::from_ptr((*ffi).message) }
            .to_string_lossy()
            .into_owned();
        unsafe { crate::errors::idevice_error_free(ffi) };
        message
    }
    #[tokio::test]
    async fn scoped_initial_and_tunnel_connections() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let index = unsafe { libc::if_nametoindex(c"lo0".as_ptr()) };
        assert_ne!(index, 0);
        let binding = Binding {
            local_ip: Ipv4Addr::LOCALHOST,
            interface_index: index,
        };
        for stage in ["rppairing", "device-tunnel"] {
            let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
                .await
                .unwrap();
            let target = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, peer) = listener.accept().await.unwrap();
                assert_eq!(peer.ip(), Ipv4Addr::LOCALHOST);
                stream.write_all(b"scoped").await.unwrap();
            });
            let mut stream = connect(target, Some(binding), stage).await.unwrap();
            let mut response = [0; 6];
            stream.read_exact(&mut response).await.unwrap();
            assert_eq!(&response, b"scoped");
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn route_selected_connection_keeps_source_binding() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let target = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, peer) = listener.accept().await.unwrap();
            assert_eq!(peer.ip(), Ipv4Addr::LOCALHOST);
            stream.write_all(b"route").await.unwrap();
        });
        let binding = Binding {
            local_ip: Ipv4Addr::LOCALHOST,
            interface_index: unsafe { libc::if_nametoindex(c"lo0".as_ptr()) },
        };
        let socket = source_bound_socket(binding).unwrap();
        assert_eq!(
            socket.local_addr().unwrap().ip(),
            std::net::IpAddr::V4(Ipv4Addr::LOCALHOST)
        );
        use std::os::fd::AsRawFd;
        let mut index: u32 = u32::MAX;
        let mut length = std::mem::size_of::<u32>() as libc::socklen_t;
        assert_eq!(
            unsafe {
                libc::getsockopt(
                    socket.as_raw_fd(),
                    libc::IPPROTO_IP,
                    libc::IP_BOUND_IF,
                    &mut index as *mut u32 as *mut libc::c_void,
                    &mut length,
                )
            },
            0
        );
        assert_eq!(index, 0);
        let mut stream = socket.connect(target).await.unwrap();
        let mut response = [0; 5];
        stream.read_exact(&mut response).await.unwrap();
        assert_eq!(&response, b"route");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn cellular_denied_policy_keeps_local_transport_and_real_failure() {
        use std::os::fd::AsRawFd;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        fn cellular_flag(socket: &tokio::net::TcpSocket) -> libc::c_int {
            let mut value: libc::c_int = -1;
            let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
            assert_eq!(
                unsafe {
                    libc::getsockopt(
                        socket.as_raw_fd(),
                        libc::IPPROTO_IP,
                        6969,
                        &mut value as *mut _ as *mut libc::c_void,
                        &mut length,
                    )
                },
                0
            );
            value
        }
        let binding = Binding {
            local_ip: Ipv4Addr::LOCALHOST,
            interface_index: unsafe { libc::if_nametoindex(c"lo0".as_ptr()) },
        };
        let ordinary = source_bound_socket(binding).unwrap();
        assert_eq!(cellular_flag(&ordinary), 0);
        let socket = cellular_denied_socket(binding).unwrap();
        assert_eq!(cellular_flag(&socket), 1);
        assert_eq!(socket.local_addr().unwrap().ip(), binding.local_ip);
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let target = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, peer) = listener.accept().await.unwrap();
            assert_eq!(peer.ip(), Ipv4Addr::LOCALHOST);
            stream.write_all(b"local").await.unwrap();
        });
        let mut stream = socket.connect(target).await.unwrap();
        let mut response = [0; 5];
        stream.read_exact(&mut response).await.unwrap();
        assert_eq!(&response, b"local");
        server.await.unwrap();
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let closed_port = listener.local_addr().unwrap();
        drop(listener);
        let error = cellular_denied_socket(binding)
            .unwrap()
            .connect(closed_port)
            .await
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::ConnectionRefused);
    }

    #[test]
    fn route_retry_is_limited_to_local_reflection_connect_errors() {
        let binding = Binding {
            local_ip: Ipv4Addr::new(10, 7, 0, 2),
            interface_index: 40,
        };
        let target: SocketAddr = "10.7.0.1:49152".parse().unwrap();
        let refused = std::io::Error::from_raw_os_error(libc::ECONNREFUSED);
        assert!(should_retry_with_route(
            target,
            binding,
            "rppairing",
            &refused
        ));
        assert!(should_retry_with_route(
            "10.7.0.1:51368".parse().unwrap(),
            binding,
            "device-tunnel",
            &refused
        ));
        assert!(!should_retry_with_route(
            "100.64.0.1:49152".parse().unwrap(),
            binding,
            "rppairing",
            &refused
        ));
        assert!(!should_retry_with_route(
            target,
            binding,
            "rppairing",
            &std::io::Error::from_raw_os_error(libc::ENXIO)
        ));
        assert!(!should_retry_with_route(
            target,
            binding,
            "rppairing",
            &std::io::Error::from_raw_os_error(libc::ETIMEDOUT)
        ));
    }

    #[tokio::test]
    async fn missing_interface_does_not_fall_back() {
        let binding = Binding {
            local_ip: Ipv4Addr::LOCALHOST,
            interface_index: u32::MAX,
        };
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        assert!(
            connect(
                listener.local_addr().unwrap(),
                Some(binding),
                "invalid-index"
            )
            .await
            .is_err()
        );
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), listener.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn native_socket_error_preserves_os_cause_through_ffi() {
        let binding = Binding {
            local_ip: Ipv4Addr::LOCALHOST,
            interface_index: u32::MAX,
        };
        // A missing interface produces a deterministic real OS socket error,
        // without depending on the runner's treatment of closed-port SYNs.
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let target = listener.local_addr().unwrap();
        let cause = connect(target, Some(binding), "rppairing")
            .await
            .unwrap_err();
        let expected_kind = format!("kind={:?}", cause.kind());
        let code = cause
            .raw_os_error()
            .expect("Darwin binding failure needs an OS code");
        let message = ffi_message(connection_error(
            cause.into(),
            Some(binding),
            "rppairing",
            target,
        ));
        assert!(message.contains("rppairing TCP connect failed:"));
        assert!(message.contains(&expected_kind));
        assert!(message.contains(&format!("os_code=Some({code})")));
        assert!(message.contains(&format!("target={target}")));
        assert!(message.contains(&format!("source=127.0.0.1; interface={}", u32::MAX)));
        let refused = ffi_message(connection_error(
            std::io::Error::from_raw_os_error(libc::ECONNREFUSED).into(),
            Some(binding),
            "rppairing",
            target,
        ));
        assert!(refused.contains("kind=ConnectionRefused"));
        assert!(refused.contains(&format!("os_code=Some({})", libc::ECONNREFUSED)));
        let unbound = ffi_message(connection_error(
            std::io::Error::from_raw_os_error(libc::ECONNREFUSED).into(),
            None,
            "rppairing",
            target,
        ));
        assert!(unbound.contains("connect: device socket io failed"));
        let timeout = ffi_message(connection_error(
            idevice::IdeviceError::Timeout,
            Some(binding),
            "device-tunnel",
            target,
        ));
        assert!(timeout.contains("device-tunnel TCP connect failed: Timeout"));
    }
}
