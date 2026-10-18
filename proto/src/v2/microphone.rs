//! USB-only iPad microphone uplink: one PCM16LE mono 16 kHz / 20 ms frame.
use super::{CommonPrefix, PacketType, WireError};

pub const MICROPHONE_HEADER_SIZE: usize = 24;
pub const MICROPHONE_PCM_BYTES: usize = 640;
pub const MICROPHONE_SAMPLE_RATE: u32 = 16_000;
pub const MICROPHONE_FRAME_SAMPLES: usize = 320;
pub const MICROPHONE_FLAG_END: u8 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MicrophoneHeader {
    pub session_id: u32,
    pub mic_seq: u32,
    pub capture_ts_us: u64,
    pub end: bool,
}

impl MicrophoneHeader {
    pub fn encode(self, pcm: &[u8]) -> Result<Vec<u8>, WireError> {
        self.validate(pcm.len())?;
        let mut bytes = vec![0; MICROPHONE_HEADER_SIZE + pcm.len()];
        CommonPrefix {
            packet_type: PacketType::Microphone,
            flags: if self.end { MICROPHONE_FLAG_END } else { 0 },
            payload_len: pcm.len() as u16,
        }
        .encode_into(&mut bytes);
        bytes[8..12].copy_from_slice(&self.session_id.to_le_bytes());
        bytes[12..16].copy_from_slice(&self.mic_seq.to_le_bytes());
        bytes[16..24].copy_from_slice(&self.capture_ts_us.to_le_bytes());
        bytes[MICROPHONE_HEADER_SIZE..].copy_from_slice(pcm);
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<(Self, &[u8]), WireError> {
        let prefix = CommonPrefix::decode(bytes)?;
        if prefix.packet_type != PacketType::Microphone {
            return Err(WireError::InvalidField("packet_type"));
        }
        if bytes.len() < MICROPHONE_HEADER_SIZE {
            return Err(WireError::Truncated);
        }
        if bytes[5] != 0 || prefix.flags & !MICROPHONE_FLAG_END != 0 {
            return Err(WireError::InvalidField("microphone_flags"));
        }
        let pcm = &bytes[MICROPHONE_HEADER_SIZE..];
        if usize::from(prefix.payload_len) != pcm.len() {
            return Err(WireError::LengthMismatch);
        }
        let header = Self {
            session_id: u32::from_le_bytes(bytes[8..12].try_into().unwrap()),
            mic_seq: u32::from_le_bytes(bytes[12..16].try_into().unwrap()),
            capture_ts_us: u64::from_le_bytes(bytes[16..24].try_into().unwrap()),
            end: prefix.flags & MICROPHONE_FLAG_END != 0,
        };
        header.validate(pcm.len())?;
        Ok((header, pcm))
    }

    fn validate(self, length: usize) -> Result<(), WireError> {
        if self.session_id == 0 {
            return Err(WireError::InvalidField("session_id"));
        }
        let expected = if self.end { 0 } else { MICROPHONE_PCM_BYTES };
        if length != expected {
            return Err(WireError::InvalidField("microphone_pcm_len"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::v2::{classify, Classified};
    fn header(end: bool) -> MicrophoneHeader {
        MicrophoneHeader {
            session_id: 0x12345678,
            mic_seq: 0x87654321,
            capture_ts_us: 0x0123456789abcdef,
            end,
        }
    }

    #[test]
    fn pcm_header_roundtrips_exact_little_endian_offsets() {
        let pcm = [0x45; MICROPHONE_PCM_BYTES];
        let bytes = header(false).encode(&pcm).unwrap();
        assert_eq!(&bytes[..8], &[0x45, 0x4d, 2, 4, 0, 0, 0x80, 2]);
        assert_eq!(
            &bytes[8..16],
            &[0x78, 0x56, 0x34, 0x12, 0x21, 0x43, 0x65, 0x87]
        );
        assert_eq!(bytes.len(), 664);
        assert_eq!(
            MicrophoneHeader::decode(&bytes).unwrap(),
            (header(false), pcm.as_slice())
        );
        assert_eq!(classify(&bytes), Classified::Microphone { flags: 0 });
    }

    #[test]
    fn end_is_header_only_and_distinct_from_silence() {
        let bytes = header(true).encode(&[]).unwrap();
        assert_eq!(bytes.len(), MICROPHONE_HEADER_SIZE);
        assert_eq!(
            MicrophoneHeader::decode(&bytes).unwrap(),
            (header(true), &[][..])
        );
        assert!(header(false).encode(&[]).is_err());
        assert!(header(true).encode(&[0; MICROPHONE_PCM_BYTES]).is_err());
    }

    #[test]
    fn malformed_flags_reserved_lengths_and_zero_session_are_rejected() {
        let valid = header(false).encode(&[0; MICROPHONE_PCM_BYTES]).unwrap();
        for len in 0..valid.len() {
            assert!(MicrophoneHeader::decode(&valid[..len]).is_err());
        }
        for (index, value) in [(3, 3), (4, 2), (5, 1), (6, 1)] {
            let mut changed = valid.clone();
            changed[index] = value;
            assert!(MicrophoneHeader::decode(&changed).is_err());
        }
        let mut changed = valid.clone();
        changed[8..12].fill(0);
        assert!(MicrophoneHeader::decode(&changed).is_err());
        let mut changed = valid.clone();
        changed.push(0);
        assert!(MicrophoneHeader::decode(&changed).is_err());
        assert!(header(false).encode(&[0; MICROPHONE_PCM_BYTES - 2]).is_err());
        assert!(header(false).encode(&[0; MICROPHONE_PCM_BYTES + 2]).is_err());
    }
}
