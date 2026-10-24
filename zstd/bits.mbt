// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A bit reader that runs **backwards**.
///
/// zstd's encoder writes bits forward, so its decoder has to read them from the
/// end of the buffer towards the beginning. The last byte carries a stop marker:
/// 0-7 zero bits and then a one, and the data lives below that one. Reading is
/// therefore a cursor descending from the stop bit, and "first bit read" becomes
/// the most significant bit of the value — which is the opposite of DEFLATE and
/// the reason this file exists rather than reusing anything.
priv struct Rev {
  data : BytesView
  /// Bit index one past the next bit to read, counted from the start of `data`.
  mut pos : Int32
}

///|
fn Rev::new(data : BytesView) -> Rev raise @moonzip.Refused {
  if data.length() == 0 {
    raise @moonzip.Truncated(at=0)
  }
  let last = data[data.length() - 1].to_int()
  if last == 0 {
    // The stop bit is always present, so a zero last byte means the stream was
    // cut or is not a bitstream at all.
    raise @moonzip.Header(
      at=data.length() - 1,
      what="a bitstream with no stop bit",
    )
  }
  let mut top = 7
  while ((last >> top) & 1) == 0 {
    top -= 1
  }
  { data, pos: (data.length() - 1) * 8 + top, }
}

///|
fn Rev::bit(self : Rev, index : Int32) -> Int32 {
  if index < 0 {
    0
  } else {
    (self.data[index / 8].to_int() >> (index % 8)) & 1
  }
}

///|
/// `n` bits, the first one read landing in the highest place.
fn Rev::take(self : Rev, n : Int32) -> Int32 raise @moonzip.Refused {
  if n == 0 {
    return 0
  }
  if self.pos < n {
    raise @moonzip.Truncated(at=self.pos / 8)
  }
  let mut value = 0
  for k in 0..<n {
    value = (value << 1) | self.bit(self.pos - 1 - k)
  }
  self.pos -= n
  value
}

///|
fn Rev::left(self : Rev) -> Int32 {
  self.pos
}

///|
/// The other half: a bit sink that fills bytes from the bottom up, because the
/// reader will take them back to front.
///
/// Writing n bits means placing the value's high bit where the reader will find
/// it first, so the sink writes from the top of the value down.
priv struct Fwd {
  out : Array[Byte]
  mut acc : UInt32
  mut held : Int32
}

///|
fn Fwd::new() -> Fwd {
  { out: [], acc: 0, held: 0, }
}

///|
fn Fwd::take(self : Fwd, value : Int32, n : Int32) -> Unit {
  if n == 0 {
    return
  }
  // Least significant bit first, into increasing positions. The reader walks the
  // same positions downward, so what it meets first is the value's *highest* bit —
  // which is exactly what `Rev::take` assumes.
  for k in 0..<n {
    let bit = (value >> k) & 1
    self.acc = self.acc | (bit.reinterpret_as_uint() << self.held)
    self.held += 1
    if self.held == 8 {
      self.out.push((self.acc & 0xFFU).reinterpret_as_int().to_byte())
      self.acc = 0
      self.held = 0
    }
  }
}

///|
/// Close the stream: a one bit, then zeros to the byte boundary. This is the stop
/// marker the reader looks for.
fn Fwd::finish(self : Fwd) -> Bytes {
  self.take(1, 1)
  if self.held > 0 {
    self.out.push((self.acc & 0xFFU).reinterpret_as_int().to_byte())
    self.acc = 0
    self.held = 0
  }
  Bytes::from_array(self.out)
}

///|
/// A bit reader that runs **forwards**, least significant bit first.
///
/// Two things in zstd are written the ordinary way round and read the ordinary
/// way round: the probability distributions, and nothing else. They still need a
/// cursor of their own, because they are read a variable number of bits at a
/// time and the reader has to be able to look before it leaps.
priv struct Fb {
  data : BytesView
  mut pos : Int32
}

///|
fn Fb::new(data : BytesView) -> Fb {
  { data, pos: 0, }
}

///|
fn Fb::at(self : Fb) -> Int32 {
  (self.pos + 7) / 8
}

///|
/// `n` bits without consuming them.
fn Fb::peek(self : Fb, n : Int32) -> Int32 raise @moonzip.Refused {
  let mut value = 0
  for k in 0..<n {
    let index = self.pos + k
    if index / 8 >= self.data.length() {
      raise @moonzip.Truncated(at=self.data.length())
    }
    let bit = (self.data[index / 8].to_int() >> (index % 8)) & 1
    value = value | (bit << k)
  }
  value
}

///|
fn Fb::skip(self : Fb, n : Int32) -> Unit {
  self.pos += n
}

///|
fn Fb::take(self : Fb, n : Int32) -> Int32 raise @moonzip.Refused {
  let value = self.peek(n)
  self.skip(n)
  value
}

///|
/// `n` bits, or as many as there are — the missing ones read as zero.
///
/// An FSE stream does not state how many symbols it holds: it ends when the bits
/// run out, and the last state's transition is completed against zeros. That is
/// not an error, so it is not an error path.
fn Rev::take_or_zero(self : Rev, n : Int32) -> Int32 {
  let mut value = 0
  for k in 0..<n {
    let index = self.pos - 1 - k
    let bit = if index >= 0 { self.bit(index) } else { 0 }
    value = (value << 1) | bit
  }
  self.pos -= n
  if self.pos < 0 {
    self.pos = 0
  }
  value
}
