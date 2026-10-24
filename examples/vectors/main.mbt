// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Print the streams this library writes, as hex, for an external checker.
///
///     moon run examples/vectors
///
/// The lines are `deflate <kind> <level> <blocks> <hex>`, `gzip <kind> <hex>`
/// and `zlib <kind> <hex>`. `scripts/conformance.py` reads them and hands each
/// stream to Python's zlib, which got the same input back or the check fails.
/// It is how "others can read what we write" stays true rather than being
/// asserted once and left to rot.

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
        ] {
        if level == 0 && blocks != Auto {
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
  }
}
