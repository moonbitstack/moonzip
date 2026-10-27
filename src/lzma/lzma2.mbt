// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// LZMA2: LZMA in chunks.
///
/// A chunk carries its own control byte, so a decoder can be handed a piece at a
/// time and a dictionary can be reset in the middle of a stream without a second
/// range coder. This is the layer both xz and 7z put on top of LZMA, which is why
/// it lives with the codec: the containers are the part that differs.

///|
/// The LZMA2 dictionary-size code: the smallest property whose decoded size is at
/// least what was asked for, because a decoder has to know how much memory to
/// reserve before it starts.
pub fn dict_code(size : Int32) -> Int32 {
  let mut code = 0
  while code < 40 {
    if decoded_dict(code) >= size {
      return code
    }
    code += 1
  }
  40
}

///|
pub fn decoded_dict(code : Int32) -> Int32 {
  if code == 40 {
    0xFFFFFFFF
  } else {
    let base = 2 | (code & 1)
    let shift = code / 2 + 11
    if shift >= 31 {
      0xFFFFFFFF
    } else {
      base << shift
    }
  }
}

///|
/// How much uncompressed data one LZMA2 chunk carries. The chunk header holds the
/// size in twenty-one bits, so two megabytes is the ceiling; a megabyte keeps the
/// loss from a bad chunk small.
let chunk_size : Int32 = 1 << 20

///|
/// LZMA2: LZMA in chunks, each with its own range coder, and a control byte that
/// says how much state to throw away first.
///
/// Every chunk resets the state and the properties, which costs a few hundred
/// forgettable decisions per megabyte and makes each chunk independent; the
/// dictionary is the only thing carried across. The first chunk must reset the
/// dictionary too — a decoder has none to start from.
pub fn lzma2(data : BytesView, dictionary : Int32, level : Int32) -> Bytes {
  let out : Array[Byte] = []
  let props = properties_of(3, 0, 2)
  let mut at = 0
  let mut first = true
  while at < data.length() {
    let stop = if data.length() - at < chunk_size {
      data.length()
    } else {
      at + chunk_size
    }
    let part = data[at:stop]
    let packed = encode(part, props, dictionary, level~)
    let unpacked = part.length() - 1
    out.push(((if first { 0xE0 } else { 0xC0 }) | (unpacked >> 16)).to_byte())
    out.push(((unpacked >> 8) & 0xFF).to_byte())
    out.push((unpacked & 0xFF).to_byte())
    let packed_size = packed.length() - 1
    out.push(((packed_size >> 8) & 0xFF).to_byte())
    out.push((packed_size & 0xFF).to_byte())
    out.push(props.to_byte())
    for b in packed {
      out.push(b)
    }
    at = stop
    first = false
  }
  out.push(b'\x00')
  Bytes::from_array(out)
}

///|
/// Decode the LZMA2 chunks starting at `at`, and say where they ended.
pub fn unlzma2(
  data : BytesView,
  at : Int32,
  decoder : Decoder,
) -> (Bytes, Int32) raise @moonzip.Refused {
  let mut cursor = at
  let mut props = 93
  while cursor < data.length() {
    let control = data[cursor].to_int()
    cursor += 1
    if control == 0 {
      break
    }
    if control == 1 || control == 2 {
      guard cursor + 2 <= data.length() else { raise @moonzip.Truncated(at~) }
      let size = ((data[cursor].to_int() << 8) | data[cursor + 1].to_int()) + 1
      cursor += 2
      guard cursor + size <= data.length() else {
        raise @moonzip.Truncated(at~)
      }
      if control == 1 {
        decoder.reset()
      }
      decoder.append(data[cursor:cursor + size])
      cursor += size
      continue
    }
    guard control >= 0x80 && cursor + 4 <= data.length() else {
      raise @moonzip.Header(
        at~,
        what="an LZMA2 chunk header the format does not define",
      )
    }
    let reset = (control >> 5) & 0x03
    let unpacked = (
        ((control & 0x1F) << 16) |
        (data[cursor].to_int() << 8) |
        data[cursor + 1].to_int()
      ) +
      1
    let packed = ((data[cursor + 2].to_int() << 8) | data[cursor + 3].to_int()) +
      1
    cursor += 4
    if reset >= 2 {
      guard cursor < data.length() else { raise @moonzip.Truncated(at~) }
      props = data[cursor].to_int()
      cursor += 1
      decoder.properties(props)
    }
    // Reset 1 means "forget the state, keep the dictionary"; 2 and 3 mean the
    // same plus new properties. The output buffer is the dictionary, so it is
    // never cleared here.
    let _ = props
    if reset >= 1 {
      decoder.reset()
    }
    guard cursor + packed <= data.length() else {
      raise @moonzip.Truncated(at~)
    }
    decoder.feed(data[cursor:cursor + packed], unpacked) |> ignore
    cursor += packed
  }
  (decoder.output(), cursor)
}
