// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The standard library's zip is the other reference this archive holds itself
/// to: APPNOTE 6.3 is the format, and a reader that opens the other side's
/// central directory and a writer whose archive the other side opens is the
/// interop the one-shot pair claims. The entries are the same ones the other
/// tests use (the `members` this package's tests already build), so a shape
/// that is a problem shows up in both at once.

///|
/// What this one writes, opened by the standard library: the names it listed and
/// the bytes it held come back as the body started with. The archive is stored
/// and deflated, the two methods the format names.
test "our zip archive opens in the standard library" {
  let archive = @zip.zip(members()[:])
  let std = @szip.read_all(archive[:])
  assert_eq(std.entries().length(), 3)
  assert_eq(std.get("a.txt"), Some(b"one"))
  assert_eq(std.get("dir/b.txt"), Some(b"two two two two two two two two"))
  assert_eq(std.get("empty"), Some(b""))
}

///|
/// A Zip64 archive from this one, opened by the standard library: the wide
/// size and offset fields are read from the extra record, which is the whole
/// reason the format has them.
test "our zip64 archive opens in the standard library" {
  let archive = @zip.zip(members()[:], zip64=true)
  let std = @szip.read_all(archive[:])
  assert_eq(std.entries().length(), 3)
  assert_eq(std.get("a.txt"), Some(b"one"))
  assert_eq(std.get("dir/b.txt"), Some(b"two two two two two two two two"))
  assert_eq(std.get("empty"), Some(b""))
}

///|
/// What the standard library writes, read by this one: it stores one member and
/// deflates another, so the read takes both methods, and the names and bytes
/// come back as they went in.
test "the standard library's zip archive reads back" {
  let sa = @szip.Archive::Archive()
  sa.add("a.txt", b"one", compression=@szip.Compression::Store)
  sa.add(
    "dir/b.txt",
    b"two two two two two two two two",
    compression=@szip.Compression::Deflate,
  )
  sa.add("empty", b"")
  let bytes = @szip.write(sa)
  let back = @zip.unzip(bytes[:])
  assert_eq(back.length(), 3)
  assert_eq(back[0].name, "a.txt")
  assert_eq(back[0].data, b"one")
  assert_eq(back[1].name, "dir/b.txt")
  assert_eq(back[1].data, b"two two two two two two two two")
  assert_eq(back[2].name, "empty")
  assert_eq(back[2].data, b"")
  // And from the front, which is the only way a reader that is receiving the
  // archive rather than holding it can go.
  let reader = @zip.Reader::new(bytes[:])
  let seen : Array[String] = []
  while true {
    match reader.next() {
      None => break
      Some(entry) => seen.push(entry.name)
    }
  }
  assert_eq(seen, ["a.txt", "dir/b.txt", "empty"])
}
