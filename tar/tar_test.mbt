// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn entries() -> Array[@tar.Entry] {
  [
    @tar.Entry::new("hello.txt", b"hello, tar world"),
    @tar.Entry::new("dir/deep.txt", b"a file in a directory"),
    @tar.Entry::directory("empty"),
    @tar.Entry::symlink("link", "hello.txt"),
    @tar.Entry::new("quiet", b"", mtime=1700000000L),
  ]
}

///|
/// A file, a nested file, a directory and a symlink all come back as they went
/// in.
test "a tar archive round-trips" {
  let archive = @tar.tar(entries()[:])
  let back = @tar.untar(archive[:])
  assert_eq(back.map(e => e.name), [
    "hello.txt", "dir/deep.txt", "empty/", "link", "quiet",
  ])
  assert_eq(back[0].data, b"hello, tar world")
  assert_eq(back[1].data, b"a file in a directory")
  assert_eq(back[2].kind, @tar.Tarball::Directory)
  assert_eq(back[2].data, b"")
  assert_eq(back[3].kind, @tar.Tarball::Symlink)
  assert_eq(back[3].link, "hello.txt")
  assert_eq(back[4].mtime, 1700000000L)
}

///|
/// The archive is reproducible: no clock is read, so the same entries give the
/// same bytes and two builds can be compared.
test "the same entries give the same bytes" {
  assert_eq(@tar.tar(entries()[:]), @tar.tar(entries()[:]))
}

///|
/// A name too long for the hundred-byte field goes into a pax record, and comes
/// back whole rather than truncated.
test "a long name survives in a pax record" {
  let long = "a-rather-long-directory-name/and-another-one/and-a-third/" +
    "a-file-with-a-name-that-does-not-fit-in-one-hundred-bytes.txt"
  assert_true(long.length() > 100)
  let archive = @tar.tar([@tar.Entry::new(long, b"deep")][:])
  let back = @tar.untar(archive[:])
  assert_eq(back.length(), 1)
  assert_eq(back[0].name, long)
  assert_eq(back[0].data, b"deep")
}

///|
/// A path that can be split between the name and the prefix field stays in the
/// ustar header, with no pax record at all — which is what every reader from
/// before 2001 can read.
test "a splittable path stays in the ustar header" {
  let head = StringBuilder()
  for _ in 0..<120 {
    head.write_char('x')
  }
  let path = head.to_string() + "/short.txt"
  let archive = @tar.tar([@tar.Entry::new(path, b"ok")][:])
  // One header, one block of data, two blocks saying the archive is over — and
  // no pax member in front, which is the point.
  assert_eq(archive.length(), 2048)
  assert_eq(@tar.untar(archive[:])[0].name, path)
}

///|
/// The names come out without trusting the sizes: tar has no index, so listing
/// is a walk.
test "tar lists without expanding anything" {
  let archive = @tar.tar(entries()[:])
  assert_eq(@tar.names(archive[:]).length(), 5)
}

///|
/// A tarball is a tar archive through gzip, and reads back the same way.
test "a tarball round-trips" {
  let archive = @tar.targz(entries()[:])
  assert_eq(archive[0].to_int(), 0x1F)
  assert_eq(archive[1].to_int(), 0x8B)
  let back = @tar.untargz(archive[:])
  assert_eq(back[0].data, b"hello, tar world")
  assert_eq(back[3].link, "hello.txt")
}

///|
/// A member bigger than one block is padded to the boundary, and the next header
/// still lands where a reader looks for it.
test "a member that is not a multiple of a block is padded" {
  let body = Bytes::make(1500, b'z')
  let archive = @tar.tar(
    [@tar.Entry::new("big", body), @tar.Entry::new("after", b"here")][:],
  )
  let back = @tar.untar(archive[:])
  assert_eq(back[0].data.length(), 1500)
  assert_eq(back[1].name, "after")
  assert_eq(back[1].data, b"here")
}

///|
/// The bound applies to a member's content, so an archive that claims a huge
/// member is refused before it is copied.
test "a member past the bound is refused" {
  let archive = @tar.tar([@tar.Entry::new("big", Bytes::make(4096, b'q'))][:])
  let error = try {
    @tar.untar(archive[:], limit=1024) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=1024)))
}

///|
/// A truncated archive is a truncated archive, not a shorter one.
test "a cut archive is refused, not silently shortened" {
  let archive = @tar.tar([@tar.Entry::new("big", Bytes::make(4096, b'q'))][:])
  let error = try {
    @tar.untar(archive[:1000]) |> ignore
    None
  } catch {
    _ => Some(true)
  }
  // Either it refuses or it reports fewer members — the one thing it may not do
  // is hand back a member whose bytes were cut off.
  assert_true(error is Some(_))
}
