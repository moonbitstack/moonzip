// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Print the streams this library writes, as hex, for an external checker.
///
///     moon run examples/vectors
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
    _ => @zip.zip(entries[:])
  }
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
    for step in [1, 7, 4096, 65536] {
      println(
        "stream gzip \{kind} \{step} \{@base16.encode(stream_gzip(body, step)[:])}",
      )
      println(
        "stream zlib \{kind} \{step} \{@base16.encode(stream_zlib(body, step)[:])}",
      )
    }
    for variant in 0..<5 {
      println(
        "zip \{kind} \{variant} \{@base16.encode(archive(body, variant)[:])}",
      )
    }
  }
}
