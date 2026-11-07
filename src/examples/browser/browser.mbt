// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Compress the bytes with the named codec, returning the compressed bytes.
/// The four the page offers: raw DEFLATE, the gzip and zlib containers, and
/// brotli. The page hands this a `Uint8Array` and takes one back.
pub fn compress(bytes : Array[Byte], format : String) -> Array[Byte] {
  let view = Bytes::from_array(bytes).exact_view()
  match format {
    "gzip" => @gzip.gzip(view).to_array()
    "zlib" => @zlib.zlib(view).to_array()
    "brotli" => @brotli.brotli(view).to_array()
    _ => @deflate.deflate(view).to_array()
  }
}

///|
/// Read the bytes back with the named codec. A body that does not carry the
/// format, or that does not pass its checksum, comes back as an empty array —
/// the page shows that as "not identical" rather than crashing.
pub fn decompress(bytes : Array[Byte], format : String) -> Array[Byte] {
  let view = Bytes::from_array(bytes).exact_view()
  match format {
    "gzip" => @gzip.gunzip(view).to_array() catch { _ => [] }
    "zlib" => @zlib.unzlib(view).to_array() catch { _ => [] }
    "brotli" => @brotli.unbrotli(view).to_array() catch { _ => [] }
    _ => @deflate.inflate(view).to_array() catch { _ => [] }
  }
}
