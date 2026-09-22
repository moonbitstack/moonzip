// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The one line that makes an archive, and the one that reads it back.
test "an archive round-trips" {
  let entries = [
    @zip.Entry::new("hello.txt", b"hello, zip world"),
    @zip.Entry::new("nested/deep.txt", b"a file in a directory"),
  ]
  let archive = @zip.zip(entries[:])
  let back = @zip.unzip(archive[:])
  assert_eq(back.length(), 2)
  assert_eq(back[0].name, "hello.txt")
  assert_eq(back[0].data, b"hello, zip world")
  assert_eq(back[1].name, "nested/deep.txt")
  assert_eq(back[1].data, b"a file in a directory")
}

///|
/// Listing an archive does not expand it: the central directory is a table at
/// the end that names every member.
test "the names come out without expanding anything" {
  let archive = @zip.zip(
    [
      @zip.Entry::new("a.txt", b"one"),
      @zip.Entry::new("b.txt", b"two"),
      @zip.Entry::new("c.txt", b"three"),
    ][:],
  )
  assert_eq(@zip.names(archive[:]), ["a.txt", "b.txt", "c.txt"])
  // And one member alone, by name.
  let one = @zip.entry(archive[:], "b.txt")
  assert_eq(one.map(e => e.data), Some(b"two"))
  // A name the archive does not hold is a question, not a failure.
  assert_eq(@zip.entry(archive[:], "nope.txt"), None)
}

///|
/// A member is never made bigger by compressing it. Random bytes do not deflate,
/// so the writer stores them instead — which is what `zip` itself does.
test "a member that does not compress is stored" {
  // Two bytes cannot be deflated into fewer than two: the block header alone
  // costs more than it could ever save. The writer stores them instead, which
  // is what `zip` does — a member should never grow by being compressed.
  let tiny = b"ab"
  let runs = Bytes::from_array(Array::make(600, b'a'))
  let archive = @zip.zip(
    [@zip.Entry::new("tiny.bin", tiny), @zip.Entry::new("runs.txt", runs)][:],
  )
  let back = @zip.unzip(archive[:])
  assert_eq(back[0].kind, @zip.Kind::Stored)
  assert_eq(back[0].data, tiny)
  assert_eq(back[1].kind, @zip.Kind::Deflated)
  assert_eq(back[1].data, runs)
  // The compressible one is much smaller than it was.
  assert_true(archive.length() < runs.length())
}

///|
/// `Stored` is the right choice for content that is already compressed, and the
/// writer honours it rather than trying anyway.
test "storing is a choice the caller can make" {
  let text = Bytes::from_array(Array::make(400, b'z'))
  let packed = @zip.zip([@zip.Entry::new("a.txt", text)][:])
  let plain = @zip.zip([@zip.Entry::new("a.txt", text, kind=Stored)][:])
  assert_true(packed.length() < plain.length())
  assert_eq(@zip.unzip(packed[:])[0].data, text)
  assert_eq(@zip.unzip(plain[:])[0].data, text)
  assert_eq(@zip.unzip(plain[:])[0].kind, @zip.Kind::Stored)
}

///|
/// The level reaches the compressor, and the preset is the one every writer uses.
test "the level is a knob" {
  let text = Array::make(4000, b'\x00')
  for i in 0..<4000 {
    text[i] = "the quick brown fox "[i % 20].to_int().to_byte()
  }
  let body = Bytes::from_array(text)
  let fastest = @zip.zip([@zip.Entry::new("a.txt", body)][:], level=1)
  let hardest = @zip.zip([@zip.Entry::new("a.txt", body)][:], level=9)
  assert_true(hardest.length() <= fastest.length())
  assert_eq(@zip.unzip(fastest[:])[0].data, body)
  assert_eq(@zip.unzip(hardest[:])[0].data, body)
  assert_eq(@zip.level, 6)
}

///|
/// A modification time survives the trip, rounded to the two seconds MS-DOS
/// date and time can hold.
test "a modification time survives, at the resolution the format has" {
  // 2026-09-10T12:34:56Z, checked against Python: a round-trip alone would
  // not have caught a systematic error in the civil-date arithmetic, because
  // both directions share it.
  let when = 1789043696L
  let archive = @zip.zip([@zip.Entry::new("a.txt", b"x", mtime=when)][:])
  let back = @zip.unzip(archive[:])[0]
  assert_eq(back.mtime, when - when % 2L)
  // The epoch is before the format's 1980 floor, so it is written as the floor
  // rather than wrapping into a date that means something else.
  let old = @zip.zip([@zip.Entry::new("a.txt", b"x")][:])
  assert_true(@zip.unzip(old[:])[0].mtime >= 315532800L)
}

///|
/// A comment rides along with its entry.
test "a comment rides with its entry" {
  let archive = @zip.zip(
    [@zip.Entry::new("a.txt", b"x", comment="written by a test")][:],
  )
  assert_eq(@zip.unzip(archive[:])[0].comment, "written by a test")
}

///|
/// A name outside ASCII goes out as UTF-8 with the flag that says so, and comes
/// back as itself.
test "a name outside ASCII" {
  let archive = @zip.zip([@zip.Entry::new("说明.txt", b"content")][:])
  assert_eq(@zip.names(archive[:]), ["说明.txt"])
  assert_eq(@zip.unzip(archive[:])[0].data, b"content")
}

///|
/// An archive is worth bounding more than a single stream is: a small one can
/// declare many large members.
test "expanding can be bounded" {
  let big = Bytes::from_array(Array::make(50000, b'\x00'))
  let archive = @zip.zip([@zip.Entry::new("big.bin", big)][:])
  assert_true(archive.length() < 1000)
  assert_eq(@zip.unzip(archive[:])[0].data.length(), 50000)
  try @zip.unzip(archive[:], limit=1000) |> ignore catch {
    e => assert_eq(e, @moonzip.TooBig(limit=1000))
  } noraise {
    _ => fail("fifty kilobytes passed a limit of one thousand")
  }
  // The bound reaches the single-entry reader too.
  try @zip.entry(archive[:], "big.bin", limit=1000) |> ignore catch {
    e => assert_eq(e, @moonzip.TooBig(limit=1000))
  } noraise {
    _ => fail("the bound did not reach the single-entry reader")
  }
}

///|
/// What a reader must refuse rather than answer something plausible for.
test "a broken archive is refused" {
  let archive = @zip.zip([@zip.Entry::new("a.txt", b"hello")][:])
  // Arbitrary bytes are not an archive.
  try @zip.names(b"not an archive at all, no"[:]) |> ignore catch {
    e => assert_true(e is @moonzip.Header(_))
  } noraise {
    _ => fail("arbitrary bytes were read as an archive")
  }
  // Nor is something too short to hold an end record.
  try @zip.names(b"PK"[:]) |> ignore catch {
    e => assert_true(e is @moonzip.Header(_))
  } noraise {
    _ => fail("two bytes were read as an archive")
  }
  // A flipped byte in the content fails its checksum.
  let bent = archive.to_array()
  bent[40] = (bent[40].to_int() ^ 0xFF).to_byte()
  try @zip.unzip(Bytes::from_array(bent)[:]) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("a corrupted member was accepted")
  }
}

///|
/// An empty archive is a valid archive — `zip -j empty.zip` writes one, and a
/// reader that chokes on it is a reader that chokes on an empty directory.
test "an archive with nothing in it" {
  let archive = @zip.zip([][:])
  assert_eq(archive.length(), 22)
  assert_eq(@zip.names(archive[:]), [])
  assert_eq(@zip.unzip(archive[:]), [])
}

///|
/// The bytes of a small archive, pinned, so a change to the layout is a change
/// a test notices rather than one a reader finds.
test "the bytes on the wire" {
  let archive = @zip.zip([@zip.Entry::new("a", b"b", kind=Stored)][:])
  // Local header: signature, version 2.0, the UTF-8 flag, stored.
  assert_eq(@base16.encode(archive[0:10].to_owned()), "504b0304140000080000")
  // The end record's signature, and the count of entries.
  let end = archive.length() - 22
  assert_eq(@base16.encode(archive[end:end + 4].to_owned()), "504b0506")
  assert_eq(archive[end + 10].to_int(), 1)
}

///|
/// A method this package does not implement is a codec away — which is what
/// keeps bzip2 or LZMA from being an edit to this file.
test "a method this package does not implement" {
  let codecs : Array[&@zip.Codec] = [Backwards::{ }]
  let archive = @zip.zip(
    [@zip.Entry::new("a.txt", b"hello", kind=Other(99))][:],
    codecs=codecs[:],
  )
  // Without the codec, a reader says so rather than guessing.
  try @zip.unzip(archive[:]) |> ignore catch {
    e => assert_true(e is @moonzip.Header(_))
  } noraise {
    _ => fail("an unknown method was read without a codec")
  }
  // With it, the entry comes back.
  let back = @zip.unzip(archive[:], codecs=codecs[:])
  assert_eq(back[0].data, b"hello")
  assert_eq(back[0].kind, @zip.Kind::Other(99))
}

///|
/// A codec of one's own: this one reverses the bytes, which is enough to prove
/// the seam carries content through unchanged.
struct Backwards {}

///|
pub impl @zip.Codec for Backwards with fn id(_self) {
  99
}

///|
pub impl @zip.Codec for Backwards with fn pack(_self, data) {
  let out : Array[Byte] = []
  for i = data.length() - 1; i >= 0; i = i - 1 {
    out.push(data[i])
  }
  Bytes::from_array(out)
}

///|
pub impl @zip.Codec for Backwards with fn unpack(_self, data, _limit) {
  let out : Array[Byte] = []
  for i = data.length() - 1; i >= 0; i = i - 1 {
    out.push(data[i])
  }
  Bytes::from_array(out)
}
