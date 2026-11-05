// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Print the streams this library writes, as hex, for an external checker.
///
///     moon run src/examples/vectors
///
/// The lines are `deflate <kind> <level> <blocks> <hex>`, `gzip <kind> <hex>`,
/// `zlib <kind> <hex>`, and `stream <form> <kind> <step> <hex>` for the writers
/// that take a body a piece at a time. `scripts/conformance.py` reads them and
/// hands each stream to Python's zlib, which got the same input back or the
/// check fails. It is how "others can read what we write" stays true rather
/// than being asserted once and left to rot.

///|
/// The seven inputs every vector is taken over: nothing, one byte, a long run,
/// text with a periodic tail, incompressible noise, a short cycle, and seventy
/// kilobytes — past the 32 KiB window, which is where a back-reference that
/// reaches too far would show.
fn sample(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  match kind {
    0 => ()
    1 => out.push(b'a')
    2 =>
      for _ in 0..<1000 {
        out.push(b'a')
      }
    3 =>
      for i in 0..<500 {
        for b in "the quick brown fox jumps over the lazy dog. " {
          out.push((b.to_int() % 256).to_byte())
        }
        out.push((i % 251).to_byte())
      }
    4 =>
      for i in 0..<3000 {
        out.push((i * 71 % 251).to_byte())
      }
    5 =>
      for i in 0..<2000 {
        out.push((i % 4).to_byte())
      }
    _ =>
      for i in 0..<70000 {
        out.push((i % 13).to_byte())
      }
  }
  Bytes::from_array(out)
}

///|
fn name_of(blocks : @deflate.Blocks) -> String {
  match blocks {
    Auto => "auto"
    Fixed => "fixed"
    Dynamic => "dynamic"
    Stored => "stored"
  }
}

///|
/// A gzip stream written in chunks of `step` bytes.
fn stream_gzip(body : Bytes, step : Int32) -> Bytes {
  let writer = @gzip.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A zlib stream written in chunks of `step` bytes.
fn stream_zlib(body : Bytes, step : Int32) -> Bytes {
  let writer = @zlib.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// One body sent as three messages on one stream, each ended by a synchronising
/// flush — the shape a connection that sends many small messages uses.
///
/// With `keep`, the window is carried from one message to the next, which is what
/// `permessage-deflate` calls context takeover; without it, each message is a
/// stream of its own. The two produce different bytes from the same body, and both
/// have to read back somewhere else, which is what the checker asks.
fn messages(body : Bytes, keep : Bool) -> Array[Bytes] {
  let writer = @deflate.Writer::new(level=6)
  let step = if body.length() / 3 > 0 { body.length() / 3 + 1 } else { 1 }
  let out : Array[Bytes] = []
  let mut at = 0
  while at < body.length() || out.length() == 0 {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    let piece : Array[Byte] = []
    for b in writer.push(body[at:stop]) {
      piece.push(b)
    }
    for b in writer.flush() {
      piece.push(b)
    }
    if !keep {
      writer.reset()
    }
    out.push(Bytes::from_array(piece))
    at = stop
  }
  out
}

///|
/// The six writers that take the body a piece at a time, each fed in chunks of
/// `step` bytes, so an external checker sees the streams they produce rather than
/// the ones a single call would.
fn stream_lz4(body : Bytes, step : Int32) -> Bytes {
  let writer = @lz4.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn stream_snappy(body : Bytes, step : Int32) -> Bytes {
  let writer = @snappy.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn stream_zstd(body : Bytes, step : Int32) -> Bytes {
  let writer = @zstd.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn stream_brotli(body : Bytes, step : Int32) -> Bytes {
  let writer = @brotli.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn stream_lzma(body : Bytes, step : Int32) -> Bytes {
  let writer = @lzma.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn stream_xz(body : Bytes, step : Int32) -> Bytes {
  let writer = @xz.Writer::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < body.length() {
    let stop = if body.length() - at < step { body.length() } else { at + step }
    for b in writer.push(body[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// An archive cut into volumes, in each of the two shapes the package writes:
/// byte ranges that must be rejoined, and the older form with disk numbers.
fn volumes(body : Bytes, spanned : Bool) -> Array[Bytes] {
  let entries = [
    @zip.Entry::new("first.txt", body),
    @zip.Entry::new("dir/second.txt", b"the second member"),
  ]
  if spanned {
    @zip.zip_spanned(entries[:], 4096, password="moonzip", aes=256)
  } else {
    @zip.zip_split(entries[:], 4096, password="moonzip", aes=256)
  }
}

///|
/// One archive per shape the writer can produce, so an external reader sees
/// each of them.
fn archive(body : Bytes, variant : Int32) -> Bytes {
  let entries = [
    @zip.Entry::new("first.txt", body),
    @zip.Entry::new("dir/second.txt", b"the second member"),
  ]
  match variant {
    0 => @zip.zip(entries[:])
    1 => @zip.zip(entries[:], zip64=true)
    2 => @zip.zip(entries[:], descriptor=true)
    3 => @zip.zip(entries[:], password="moonzip")
    4 => @zip.zip(entries[:], zip64=true, descriptor=true)
    // The six encrypted shapes: three key lengths, and AE-1 against AE-2.
    5 => @zip.zip(entries[:], password="moonzip", aes=128)
    6 => @zip.zip(entries[:], password="moonzip", aes=192)
    7 => @zip.zip(entries[:], password="moonzip", aes=256)
    8 => @zip.zip(entries[:], password="moonzip", aes=128, ae=2)
    9 => @zip.zip(entries[:], password="moonzip", aes=192, ae=2)
    _ => @zip.zip(entries[:], password="moonzip", aes=256, ae=2)
  }
}

///|
/// A 7z archive written one entry at a time, assembled in the order the format
/// requires: the signature header in front, then the folders, then the
/// directory.
fn stream_sevenz(kind : Int32) -> Bytes {
  let writer = @sevenz.Writer::new(level=6)
  let body : Array[Byte] = []
  for
    b in writer.add(
      @sevenz.Entry::new("first.txt", sample(kind), mtime=1700000000L),
    ) {
    body.push(b)
  }
  for
    b in writer.add(@sevenz.Entry::new("dir/second.txt", b"the second member")) {
    body.push(b)
  }
  let tail = writer.finish()
  let start = writer.signature()
  let out : Array[Byte] = []
  for b in start {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  for b in tail {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn main {
  for kind in 0..<7 {
    let body = sample(kind)
    for level in [0, 1, 6, 7, 9] {
      for
        blocks in [
          @deflate.Blocks::Auto,
          @deflate.Blocks::Fixed,
          @deflate.Blocks::Dynamic,
          @deflate.Blocks::Stored,
        ] {
        if level == 0 && blocks != @deflate.Blocks::Auto {
          continue
        }
        let made = @deflate.deflate(body[:], level~, blocks~)
        println(
          "deflate \{kind} \{level} \{name_of(blocks)} \{@base16.encode(made[:])}",
        )
      }
    }
    for keep in [true, false] {
      let parts = messages(body, keep)
      let line = StringBuilder()
      line.write_string(
        "messages \{if keep { "keep" } else { "reset" }} \{kind}",
      )
      for part in parts {
        line.write_string(" \{@base16.encode(part[:])}")
      }
      println(line.to_string())
    }
    println("sevenz \{kind} \{@base16.encode(stream_sevenz(kind)[:])}")
    println("gzip \{kind} \{@base16.encode(@gzip.gzip(body[:])[:])}")
    println("zlib \{kind} \{@base16.encode(@zlib.zlib(body[:])[:])}")
    println("lzma \{kind} \{@base16.encode(@lzma.lzma(body[:])[:])}")
    println("xz \{kind} \{@base16.encode(@xz.xz(body[:])[:])}")
    for level in [1, 3, 9] {
      // zstd's judge is Node's `zlib`, which is not a thing this script can
      // call, so the checksum travels with the line and `zstd_check.js` compares
      // it. A reader that decodes to the right bytes is the only claim worth
      // making.
      println(
        "zstd \{kind} \{level} \{@moonzip.crc32(body[:])} \{@base16.encode(@zstd.zstd(body[:], level~)[:])}",
      )
    }
    for level in [1, 9] {
      println(
        "bzip2 \{kind} \{level} \{@base16.encode(@bzip2.bzip2(body[:], level~)[:])}",
      )
    }
    for window in [16, 22] {
      // Brotli's judge is Node's `zlib` too, for the same reason as zstd: the
      // checksum rides along on the line and `brotli_check.js` compares it.
      println(
        "brotli \{kind} \{window} \{@moonzip.crc32(body[:])} \{@base16.encode(@brotli.brotli(body[:], window~)[:])}",
      )
    }
    for step in [1, 7, 4096, 65536] {
      println(
        "stream gzip \{kind} \{step} \{@base16.encode(stream_gzip(body, step)[:])}",
      )
      println(
        "stream zlib \{kind} \{step} \{@base16.encode(stream_zlib(body, step)[:])}",
      )
      println(
        "stream lz4 \{kind} \{step} \{@base16.encode(stream_lz4(body, step)[:])}",
      )
      println(
        "stream snappy \{kind} \{step} \{@base16.encode(stream_snappy(body, step)[:])}",
      )
      println(
        "stream zstd \{kind} \{step} \{@base16.encode(stream_zstd(body, step)[:])}",
      )
      println(
        "stream brotli \{kind} \{step} \{@base16.encode(stream_brotli(body, step)[:])}",
      )
      println(
        "stream lzma \{kind} \{step} \{@base16.encode(stream_lzma(body, step)[:])}",
      )
      println(
        "stream xz \{kind} \{step} \{@base16.encode(stream_xz(body, step)[:])}",
      )
    }
    for (name, spanned) in [("split", false), ("spanned", true)] {
      // A volume set is written one file at a time, so the external reader sees
      // the pieces rather than the archive they make.
      let mut line = "zipvol \{kind} \{name}"
      for piece in volumes(body, spanned) {
        line = line + " " + @base16.encode(piece[:])
      }
      println(line)
    }
    for variant in 0..<11 {
      println(
        "zip \{kind} \{variant} \{@base16.encode(archive(body, variant)[:])}",
      )
    }
  }
}
