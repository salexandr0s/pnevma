use serde::{Deserialize, Serialize};

/// Messages sent from the proxy (client) to the session backend.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProxyMessage {
    /// Raw terminal input bytes.
    Input(Vec<u8>),
    /// Terminal resize event.
    Resize { cols: u16, rows: u16 },
    /// Client is detaching gracefully.
    Detach,
    /// Keep-alive ping.
    Ping,
}

/// Messages sent from the session backend to the proxy (client).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum BackendMessage {
    /// Raw terminal output bytes.
    Output(Vec<u8>),
    /// Backend process exited with an optional exit code.
    Exited(Option<i32>),
    /// Keep-alive pong.
    Pong,
    /// An error occurred in the backend.
    Error(String),
}

/// 4-byte length-prefix framing for Unix socket transport.
///
/// Wire format: `[u32 big-endian length][payload bytes]`
///
/// The payload is serde_json-encoded `ProxyMessage` or `BackendMessage`.
/// Maximum frame size is 16 MB to prevent runaway allocations.
pub const MAX_FRAME_SIZE: u32 = 16 * 1024 * 1024;

/// Encode a message into a length-prefixed frame.
pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    let len = payload.len();
    if len > MAX_FRAME_SIZE as usize {
        return Err(FrameError::PayloadTooLarge {
            size: len,
            max: MAX_FRAME_SIZE as usize,
        });
    }
    let mut buf = Vec::with_capacity(4 + len);
    buf.extend_from_slice(&(len as u32).to_be_bytes());
    buf.extend_from_slice(payload);
    Ok(buf)
}

/// Read the length prefix from a 4-byte header, returning the payload size.
pub fn decode_frame_header(header: &[u8; 4]) -> Result<u32, FrameError> {
    let len = u32::from_be_bytes(*header);
    if len > MAX_FRAME_SIZE {
        return Err(FrameError::PayloadTooLarge {
            size: len as usize,
            max: MAX_FRAME_SIZE as usize,
        });
    }
    Ok(len)
}

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("frame payload too large: {size} bytes (max {max})")]
    PayloadTooLarge { size: usize, max: usize },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_encode_decode_roundtrip() {
        let payload = b"hello world";
        let frame = encode_frame(payload).unwrap();

        assert_eq!(frame.len(), 4 + payload.len());

        let header: [u8; 4] = frame[..4].try_into().unwrap();
        let decoded_len = decode_frame_header(&header).unwrap();
        assert_eq!(decoded_len as usize, payload.len());

        let decoded_payload = &frame[4..4 + decoded_len as usize];
        assert_eq!(decoded_payload, payload);
    }

    #[test]
    fn frame_rejects_oversized_payload() {
        let huge = vec![0u8; MAX_FRAME_SIZE as usize + 1];
        assert!(encode_frame(&huge).is_err());
    }

    #[test]
    fn frame_header_rejects_oversized_length() {
        let header = (MAX_FRAME_SIZE + 1).to_be_bytes();
        assert!(decode_frame_header(&header).is_err());
    }

    #[test]
    fn proxy_message_serde_roundtrip() {
        let msgs = vec![
            ProxyMessage::Input(b"ls\n".to_vec()),
            ProxyMessage::Resize {
                cols: 120,
                rows: 40,
            },
            ProxyMessage::Detach,
            ProxyMessage::Ping,
        ];
        for msg in msgs {
            let json = serde_json::to_vec(&msg).unwrap();
            let decoded: ProxyMessage = serde_json::from_slice(&json).unwrap();
            assert_eq!(msg, decoded);
        }
    }

    #[test]
    fn backend_message_serde_roundtrip() {
        let msgs = vec![
            BackendMessage::Output(b"drwxr-xr-x  5 user\n".to_vec()),
            BackendMessage::Exited(Some(0)),
            BackendMessage::Exited(None),
            BackendMessage::Pong,
            BackendMessage::Error("something broke".to_string()),
        ];
        for msg in msgs {
            let json = serde_json::to_vec(&msg).unwrap();
            let decoded: BackendMessage = serde_json::from_slice(&json).unwrap();
            assert_eq!(msg, decoded);
        }
    }

    #[test]
    fn frame_encode_decode_with_serde_proxy_message() {
        let msg = ProxyMessage::Input(b"echo hello\n".to_vec());
        let payload = serde_json::to_vec(&msg).unwrap();
        let frame = encode_frame(&payload).unwrap();

        let header: [u8; 4] = frame[..4].try_into().unwrap();
        let len = decode_frame_header(&header).unwrap() as usize;
        let decoded: ProxyMessage = serde_json::from_slice(&frame[4..4 + len]).unwrap();
        assert_eq!(msg, decoded);
    }

    #[test]
    fn frame_encode_decode_with_serde_backend_message() {
        let msg = BackendMessage::Output(b"total 42\n".to_vec());
        let payload = serde_json::to_vec(&msg).unwrap();
        let frame = encode_frame(&payload).unwrap();

        let header: [u8; 4] = frame[..4].try_into().unwrap();
        let len = decode_frame_header(&header).unwrap() as usize;
        let decoded: BackendMessage = serde_json::from_slice(&frame[4..4 + len]).unwrap();
        assert_eq!(msg, decoded);
    }
}
