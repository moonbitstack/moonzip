// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A small release packer: a few in-memory files, the big one stream-compressed
/// a piece at a time, wrapped in four containers — tar, tar.gz, a passworded
/// zip, and a solid 7z — then every container opened again and checked. It is a
/// "complete system" in miniature: the streaming writer, the containers, and the
/// read-back that proves the bytes survived.
///
///     moon run examples/bundle
fn big() -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<4000 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
    out.push((i % 251).to_byte())
  }
  Bytes::from_array(out)
}

fn main raise {
  // The files: a small note and a large body.
  let readme = b"moonzip release\n"
  let original = big()
  println("original big.bin -> \{original.length()} bytes")

  // Stream-compress the big file four kilobytes at a time, so it is never held
  // compressed-whole. The result is an ordinary gzip stream we can store.
  let writer = @gzip.Writer::new(level=9)
  let compressed : Array[Byte] = []
  let mut at = 0
  while at < original.length() {
    let stop = if original.length() - at < 4096 {
      original.length()
    } else {
      at + 4096
    }
    for b in writer.push(original[at:stop]) {
      compressed.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    compressed.push(b)
  }
  let bigbin = Bytes::from_array(compressed)
  println("compressed big.bin -> \{bigbin.length()} bytes")

  // tar holds the files and a directory entry; the directory also exists in 7z.
  let tarball = @tar.tar([
    @tar.Entry::new("readme.txt", readme),
    @tar.Entry::new("big.bin", bigbin),
    @tar.Entry::directory("docs"),
  ][:])
  let gzipped = @tar.targz([
    @tar.Entry::new("readme.txt", readme),
    @tar.Entry::new("big.bin", bigbin),
  ][:])

  // zip carries the same files under a password; it has no directory entry.
  let zipped = @zip.zip([
    @zip.Entry::new("readme.txt", readme),
    @zip.Entry::new("big.bin", bigbin),
  ][:], password="release-key")

  // 7z, solid, with the LZMA2 method the format is built on.
  let seven = @sevenz.sevenz([
    @sevenz.Entry::new("readme.txt", readme),
    @sevenz.Entry::new("big.bin", bigbin),
    @sevenz.Entry::directory("docs"),
  ][:], how=@sevenz.Method::Lzma2, solid=true)

  // Open everything again.
  let t_members = @tar.untar(tarball[:])
  let tg_members = @tar.untargz(gzipped[:])
  let z_members = @zip.unzip(zipped[:], password="release-key")
  let s_members = @sevenz.un7z(seven[:])

  println(
    "tar    -> \{tarball.length()} bytes, \{t_members.length()} members",
  )
  println(
    "tar.gz -> \{gzipped.length()} bytes, \{tg_members.length()} members",
  )
  println(
    "zip    -> \{zipped.length()} bytes, \{z_members.length()} members",
  )
  println(
    "7z     -> \{seven.length()} bytes, \{s_members.length()} members",
  )

  // The big member came back intact in every container.
  let back_tar = t_members[1].data
  let back_tgz = tg_members[1].data
  let back_zip = z_members[1].data
  let back_7z = s_members[1].data
  println(
    "big.bin roundtrip across 4 containers: \{back_tar == bigbin && back_tgz == bigbin && back_zip == bigbin && back_7z == bigbin}",
  )
}
