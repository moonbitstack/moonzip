// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Wrap DEFLATE output in a zlib container.
///
/// This, not raw DEFLATE, is what HTTP's `Content-Encoding: deflate` was
/// specified to mean — a detail that half the servers on the web got wrong,
/// which is why `gzip` won.
pub fn zlib(data : BytesView) -> Bytes {
  // CMF: DEFLATE with a 32 KiB window. FLG: no preset dictionary, and the two
  // check bits chosen so the pair is a multiple of 31 (RFC 1950 §2.2).
  let cmf = 0x78
  let flg = 31 - cmf * 256 % 31
  let out : Array[Byte] = [cmf.to_byte(), flg.to_byte()]
  for b in @deflate.deflate(data) {
    out.push(b)
  }
  let sum = adler32(data)
  for i in 0..<4 {
    out.push(((sum >> ((3 - i) * 8)) & 0xFFU).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Read a zlib container and decompress what is in it.
pub fn unzlib(data : BytesView) -> Bytes raise @moonzip.Broken {
  if data.length() < 6 {
    raise @moonzip.Truncated(at=data.length())
  }
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  if (cmf & 0x0F) != 8 {
    raise @moonzip.Header(
      at=0,
      what="a compression method zlib does not define",
    )
  }
  if (cmf * 256 + flg) % 31 != 0 {
    raise @moonzip.Header(at=0, what="the header check bits do not add up")
  }
  if (flg & 0x20) != 0 {
    raise @moonzip.Header(
      at=1,
      what="a preset dictionary, which is not supported",
    )
  }
  let end = data.length() - 4
  let body = @deflate.inflate(data[2:end])
  let mut want = 0U
  for i in 0..<4 {
    want = (want << 8) | data[end + i].to_uint()
  }
  let got = adler32(body[:])
  if want != got {
    raise @moonzip.Checksum(want~, got~)
  }
  body
}

///|
/// Adler-32 (RFC 1950 §9): two running sums modulo the largest prime below
/// 65536. Cheaper than a CRC and weaker, which is the trade zlib made.
pub fn adler32(data : BytesView) -> UInt {
  let mut a = 1U
  let mut b = 0U
  // 5552 is the most bytes that can be added before the sums could overflow
  // 32 bits, so the modulo runs once a block instead of once a byte.
  let mut at = 0
  while at < data.length() {
    let stop = if data.length() - at < 5552 { data.length() } else { at + 5552 }
    while at < stop {
      a += data[at].to_uint()
      b += a
      at += 1
    }
    a = a % 65521U
    b = b % 65521U
  }
  (b << 16) | a
}
