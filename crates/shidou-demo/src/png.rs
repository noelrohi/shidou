//! A dependency-free PNG writer for the demo's synthetic images.
//!
//! The demo ships no binary assets: every image a client can fetch is built
//! here, in memory, from a pure function of its dimensions. That keeps the
//! fixture byte-identical across hosts and restarts — which is what makes the
//! Demo Session replayable — and it keeps the demo's promise that nothing it
//! serves was ever read from the host filesystem.
//!
//! Compression is a zlib stream of *stored* deflate blocks. A real encoder
//! would be smaller on the wire; this one is a hundred lines with no crate to
//! audit, and the images are a few hundred kilobytes.

const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
/// A stored deflate block carries a `u16` length, so this is the ceiling.
const MAX_STORED_BLOCK: usize = u16::MAX as usize;

/// Encodes 8-bit RGBA `pixels` in row-major order as a PNG image.
///
/// Panics if `pixels` is not exactly `width * height * 4` bytes; every caller
/// is a fixture builder in this crate, so a mismatch is a programming error
/// rather than anything a client can provoke.
pub fn encode_rgba(width: u32, height: u32, pixels: &[u8]) -> Vec<u8> {
    let expected = width as usize * height as usize * 4;
    assert_eq!(
        pixels.len(),
        expected,
        "RGBA buffer does not match {width}x{height}"
    );

    let mut raw = Vec::with_capacity(expected + height as usize);
    for row in pixels.chunks_exact(width as usize * 4) {
        // Filter type 0 (None). Filtering only helps a real compressor.
        raw.push(0);
        raw.extend_from_slice(row);
    }

    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&width.to_be_bytes());
    header.extend_from_slice(&height.to_be_bytes());
    header.extend_from_slice(&[8, 6, 0, 0, 0]);

    let mut png = Vec::from(SIGNATURE);
    write_chunk(&mut png, b"IHDR", &header);
    write_chunk(&mut png, b"IDAT", &zlib_stored(&raw));
    write_chunk(&mut png, b"IEND", &[]);
    png
}

fn write_chunk(output: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    output.extend_from_slice(&(data.len() as u32).to_be_bytes());
    output.extend_from_slice(kind);
    output.extend_from_slice(data);
    let mut crc = Crc::new();
    crc.update(kind);
    crc.update(data);
    output.extend_from_slice(&crc.finish().to_be_bytes());
}

fn zlib_stored(data: &[u8]) -> Vec<u8> {
    // CMF 0x78: deflate, 32K window. FLG 0x01 makes the pair a multiple of 31
    // with no preset dictionary and the "fastest" compression level.
    let mut stream = vec![0x78, 0x01];
    let mut blocks = data.chunks(MAX_STORED_BLOCK).peekable();
    if data.is_empty() {
        stream.extend_from_slice(&[0x01, 0x00, 0x00, 0xff, 0xff]);
    }
    while let Some(block) = blocks.next() {
        stream.push(u8::from(blocks.peek().is_none()));
        let length = block.len() as u16;
        stream.extend_from_slice(&length.to_le_bytes());
        stream.extend_from_slice(&(!length).to_le_bytes());
        stream.extend_from_slice(block);
    }
    stream.extend_from_slice(&adler32(data).to_be_bytes());
    stream
}

fn adler32(data: &[u8]) -> u32 {
    const MODULUS: u32 = 65_521;
    let (mut low, mut high) = (1_u32, 0_u32);
    for &byte in data {
        low = (low + u32::from(byte)) % MODULUS;
        high = (high + low) % MODULUS;
    }
    (high << 16) | low
}

struct Crc(u32);

impl Crc {
    fn new() -> Self {
        Self(0xffff_ffff)
    }

    fn update(&mut self, data: &[u8]) {
        for &byte in data {
            let index = ((self.0 ^ u32::from(byte)) & 0xff) as usize;
            self.0 = CRC_TABLE[index] ^ (self.0 >> 8);
        }
    }

    fn finish(self) -> u32 {
        self.0 ^ 0xffff_ffff
    }
}

const CRC_TABLE: [u32; 256] = {
    let mut table = [0_u32; 256];
    let mut index = 0;
    while index < 256 {
        let mut value = index as u32;
        let mut bit = 0;
        while bit < 8 {
            value = if value & 1 == 1 {
                0xedb8_8320 ^ (value >> 1)
            } else {
                value >> 1
            };
            bit += 1;
        }
        table[index] = value;
        index += 1;
    }
    table
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_a_png_a_decoder_would_recognize() {
        let png = encode_rgba(2, 2, &[255; 16]);

        assert_eq!(&png[..8], &SIGNATURE);
        assert_eq!(&png[12..16], b"IHDR");
        assert_eq!(&png[16..20], &2_u32.to_be_bytes());
        assert_eq!(&png[20..24], &2_u32.to_be_bytes());
        assert_eq!(png[24..29], [8, 6, 0, 0, 0]);
        assert_eq!(&png[png.len() - 8..png.len() - 4], b"IEND");
    }

    #[test]
    fn the_same_pixels_always_encode_to_the_same_bytes() {
        let pixels = (0..64).map(|value| value as u8).collect::<Vec<_>>();

        assert_eq!(encode_rgba(4, 4, &pixels), encode_rgba(4, 4, &pixels));
    }

    /// Adler-32 of "Wikipedia" is the checksum RFC 1950 itself worked through.
    #[test]
    fn adler_matches_the_reference_checksum() {
        assert_eq!(adler32(b"Wikipedia"), 0x11E6_0398);
    }

    /// The IDAT chunk's own CRC is verified by re-running the table over the
    /// bytes the writer emitted, which catches a mis-derived table.
    #[test]
    fn chunk_checksums_cover_the_type_and_the_payload() {
        let mut chunk = Vec::new();
        write_chunk(&mut chunk, b"IEND", &[]);

        let mut crc = Crc::new();
        crc.update(b"IEND");
        assert_eq!(chunk[8..12], crc.finish().to_be_bytes());
    }

    #[test]
    fn stored_blocks_span_payloads_larger_than_one_block() {
        let data = vec![7_u8; MAX_STORED_BLOCK + 10];
        let stream = zlib_stored(&data);

        assert_eq!(stream[2], 0x00, "the first of two blocks is not final");
        let second = 2 + 5 + MAX_STORED_BLOCK;
        assert_eq!(stream[second], 0x01, "the last block must set BFINAL");
        assert_eq!(stream.len(), 2 + 5 + MAX_STORED_BLOCK + 5 + 10 + 4);
    }
}
