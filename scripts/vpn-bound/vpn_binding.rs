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
        let stream = socket.connect(target).await?;
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

#[cfg(all(test, target_vendor = "apple"))]
mod tests {
    use super::*;
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
}
