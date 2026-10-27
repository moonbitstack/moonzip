// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much input one chunk holds. The framing format caps a chunk at sixty-four
/// kilobytes, which is small enough that a decoder can work without a buffer it
/// has to plan for.
let chunk_size : Int32 = 65536

///|
/// The ten bytes every stream starts with: a chunk header, a length of six, and
/// the word `sNaPpY`. A decoder that does not see it is not looking at a stream.
let identifier : FixedArray[Int32] = [
  0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59,
]

///|
/// Wrap Snappy blocks in the framing format.
///
/// The stream identifier comes first, then a chunk per sixty-four kilobytes —
/// compressed with a masked CRC-32C when compressing helped, verbatim with one
/// when it did not. A chunk that grew would be a chunk that cost time to decode
/// and bytes to store, so the format has a way to say "verbatim" and this uses
/// it.
pub fn frame(data : BytesView) -> Bytes {
  let out : Array[Byte] = []
  for b in identifier {
    out.push(b.to_byte())
  }
  let n = data.length()
  let mut at = 0
  // An empty input is a stream with no chunks at all, which is still a stream.
  while at < n {
    let stop = if n - at < chunk_size { n } else { at + chunk_size }
    let part = data[at:stop]
    let packed = snappy(part)
    let sum = @moonzip.mask_crc32c(@moonzip.crc32c(part))
    if packed.length() < part.length() {
      out.push(b'\x00')
      le24(out, packed.length() + 4)
      le32(out, sum)
      for b in packed {
        out.push(b)
      }
    } else {
      out.push(b'\x01')
      le24(out, part.length() + 4)
      le32(out, sum)
      for b in part {
        out.push(b)
      }
    }
    at = stop
  }
  Bytes::from_array(out)
}

///|
/// Read a framed stream back.
///
/// `checksum` is what makes the CRC-32C in each chunk mean something; a caller
/// recovering what arrived from a broken transfer turns it off. A skippable chunk
/// — the format's way of letting a caller put its own data in the middle — is
/// stepped over, and an unskippable one is refused, because that is the
/// difference the two ranges of type numbers exist to make.
pub fn unframe(
  data : BytesView,
  checksum~ : Bool = true,
  limit? : Int32,
) -> Bytes raise @moonzip.Refused {
  let bound = match limit {
    Some(n) => n
    None => -1
  }
  let out : Array[Byte] = []
  let mut at = 0
  let mut seen_identifier = false
  while at < data.length() {
    let kind = data[at].to_int()
    guard at + 4 <= data.length() else { raise @moonzip.Truncated(at~) }
    let length = data[at + 1].to_int() |
      (data[at + 2].to_int() << 8) |
      (data[at + 3].to_int() << 16)
    let body_at = at + 4
    guard body_at + length <= data.length() else {
      raise @moonzip.Truncated(at=body_at)
    }
    let body = data[body_at:body_at + length]
    at = body_at + length
    match kind {
      0xFF => {
        guard length == 6 else {
          raise @moonzip.Header(
            at~,
            what="a stream identifier of the wrong length",
          )
        }
        for i in 0..<6 {
          if body[i] != identifier[i + 4].to_byte() {
            raise @moonzip.Header(at~, what="not a Snappy stream")
          }
        }
        if seen_identifier {
          raise @moonzip.Header(at~, what="a second stream identifier")
        }
        seen_identifier = true
      }
      0x00 | 0x01 => {
        guard seen_identifier else {
          raise @moonzip.Header(
            at~,
            what="a chunk before the stream identifier",
          )
        }
        guard length >= 4 else { raise @moonzip.Truncated(at~) }
        let want = read32(body, 0)
        let made = if kind == 0x00 {
          unsnappy(body[4:], limit?)
        } else {
          body[4:].to_owned()
        }
        if bound >= 0 && out.length() + made.length() > bound {
          raise @moonzip.TooBig(limit=bound)
        }
        if checksum {
          let got = @moonzip.mask_crc32c(@moonzip.crc32c(made[:]))
          if want != got {
            raise @moonzip.Checksum(want~, got~)
          }
        }
        for b in made {
          out.push(b)
        }
      }
      // The padding, reserved and skippable ranges: step over them.
      kind if kind >= 0x80 => ()
      _ =>
        raise @moonzip.Header(
          at~,
          what="an unskippable chunk of a type this reader does not know",
        )
    }
  }
  // A stream with no identifier at all is not a stream, and saying so beats
  // handing back an empty body that looks like a successful read of nothing.
  guard seen_identifier else {
    raise @moonzip.Header(at=0, what="not a Snappy stream")
  }
  Bytes::from_array(out)
}

///|
fn le24(out : Array[Byte], value : Int32) -> Unit {
  for i in 0..<3 {
    out.push(((value >> (i * 8)) & 0xFF).to_byte())
  }
}

///|
fn le32(out : Array[Byte], value : UInt32) -> Unit {
  for i in 0..<4 {
    out.push(((value >> (i * 8)) & 0xFFU).to_byte())
  }
}

///|
fn read32(data : BytesView, at : Int32) -> UInt32 {
  data[at].to_uint() |
  (data[at + 1].to_uint() << 8) |
  (data[at + 2].to_uint() << 16) |
  (data[at + 3].to_uint() << 24)
}
