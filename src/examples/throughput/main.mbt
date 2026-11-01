// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Throughput for the one-shot codecs: compress and decompress a fixed body and
/// report megabytes per second, taking the best of several runs after a warm-up.
/// The body is a deterministic mix of words and numbers that compresses about
/// three to one — close to text and source — and the generator is written out
/// below rather than loaded, so the same bytes can be fed to an external zlib for
/// an honest comparison.
///
///     moon run src/examples/throughput --target native --release
///
/// The numbers are machine-specific and the build type matters — a debug build is
/// several times slower than a release one — so quote release-build numbers and
/// say so. `--release` is the flag that produces them.
fn corpus() -> Bytes {
  // A deterministic mix of words and numbers, so it compresses about three to
  // one — close to text and source — rather than the two-hundred-to-one a body
  // of one repeated sentence reaches, where the rate measures memcpy more than
  // a decoder. The generator is written out here so an external zlib can be fed
  // exactly the same bytes and the comparison is honest.
  let words = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota",
    "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi",
  ]
  let out : Array[Byte] = []
  let mut state : UInt32 = 123456789U
  while out.length() < 1500000 {
    state = state * 1103515245U + 12345U
    let word = words[((state >> 16).reinterpret_as_int()) % 16]
    for b in @utf8.encode(word) {
      out.push(b)
    }
    out.push(b' ')
    let n = ((state >> 8) % 1000U).reinterpret_as_int()
    for ch in n.to_string() {
      out.push((ch.to_int() & 0xFF).to_byte())
    }
    out.push(b' ')
  }
  Bytes::from_array(out)
}

///|
/// The fastest of five timed runs, in microseconds, after one warm-up. The best
/// run is the one least disturbed by a scheduler or a cold cache, which is what a
/// throughput figure is trying to name.
fn best(action : () -> Unit raise) -> Double raise {
  action()
  let mut fastest = -1.0
  for _ in 0..<5 {
    let start = @bench.monotonic_clock_start()
    action()
    let dt = @bench.monotonic_clock_end(start)
    if fastest < 0.0 || dt < fastest {
      fastest = dt
    }
  }
  fastest
}

///|
fn report(name : String, bytes : Int, micros : Double) -> Unit {
  // Bytes per microsecond is megabytes per second: 1e6 bytes over 1e6 µs.
  let rate = if micros <= 0.0 { 0.0 } else { bytes.to_double() / micros }
  println("\{name}: \{rate} MB/s")
}

///|
fn main raise {
  let data = corpus()
  let n = data.length()
  println("body: \{n} bytes of words and numbers")
  let mut d = b""
  report("deflate write", n, best(fn() { d = @deflate.deflate(data[:]) }))
  let mut db = b""
  report("deflate read ", n, best(fn() raise { db = @deflate.inflate(d[:]) }))
  let mut g = b""
  report("gzip    write", n, best(fn() { g = @gzip.gzip(data[:]) }))
  let mut gb = b""
  report("gzip    read ", n, best(fn() raise { gb = @gzip.gunzip(g[:]) }))
  let mut z = b""
  report("zlib    write", n, best(fn() { z = @zlib.zlib(data[:]) }))
  let mut zb = b""
  report("zlib    read ", n, best(fn() raise { zb = @zlib.unzlib(z[:]) }))
  let mut s = b""
  report("zstd    write", n, best(fn() { s = @zstd.zstd(data[:]) }))
  let mut sb = b""
  report("zstd    read ", n, best(fn() raise { sb = @zstd.unzstd(s[:]) }))
  let mut br = b""
  report("brotli  write", n, best(fn() { br = @brotli.brotli(data[:]) }))
  let mut brb = b""
  report("brotli  read ", n, best(fn() raise { brb = @brotli.unbrotli(br[:]) }))
  if db.length() != n ||
    gb.length() != n ||
    zb.length() != n ||
    sb.length() != n ||
    brb.length() != n {
    abort("a round trip did not return the body")
  }
}
