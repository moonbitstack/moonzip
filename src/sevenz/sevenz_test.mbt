// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The members every round-trip test uses: two files with content, a directory,
/// a file with none, and a name that only survives as UTF-16.
fn members() -> Array[@sevenz.Entry] {
  [
    @sevenz.Entry::new(
      "readme.txt",
      b"a member of an archive\n",
      mtime=1700000000L,
    ),
    @sevenz.Entry::new("data/table.csv", b"name,size\nreadme,24\n"),
    @sevenz.Entry::directory("logs"),
    @sevenz.Entry::new("blank", b""),
    @sevenz.Entry::new("naïve/grüße.txt", b"an umlaut, twice\n"),
  ]
}

///|
/// Every shape the writer can produce reads back, with the same members in the
/// same order.
test "7z round-trips" {
  for how in [@sevenz.Method::Copy, @sevenz.Method::Lzma, @sevenz.Method::Lzma2] {
    for solid in [true, false] {
      let given = members()
      let archive = @sevenz.sevenz(given[:], how~, solid~)
      let back = @sevenz.un7z(archive[:])
      assert_eq(back.length(), given.length())
      for i in 0..<given.length() {
        assert_eq(back[i].name, given[i].name)
        assert_eq(back[i].data, given[i].data)
        assert_eq(back[i].kind, given[i].kind)
      }
    }
  }
}

///|
/// The modification time survives, to the second. 7-Zip stores a hundred-
/// nanosecond count since 1601, so the only thing that can be lost is precision
/// the caller never had.
test "the time survives the round trip" {
  let given = [@sevenz.Entry::new("stamped.txt", b"x", mtime=1700000000L)]
  let back = @sevenz.un7z(@sevenz.sevenz(given[:])[:])
  assert_eq(back[0].mtime, 1700000000L)
}

///|
/// Compression actually compresses, and the levels differ.
test "text gets smaller" {
  let body : Array[Byte] = []
  for i in 0..<2000 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      body.push((b.to_int() % 256).to_byte())
    }
    body.push((i % 251).to_byte())
  }
  let data = Bytes::from_array(body)
  let archive = @sevenz.sevenz(
    [@sevenz.Entry::new("text.txt", data)][:],
    level=9,
  )
  assert_true(archive.length() * 8 < data.length())
  assert_eq(@sevenz.un7z(archive[:])[0].data, data)
}

///|
/// A solid archive is smaller than the same files in separate folders, which is
/// the whole reason the format has folders.
test "solid is smaller than separate" {
  let body : Array[Byte] = []
  for _ in 0..<300 {
    for b in "a phrase that appears in both files, at length. " {
      body.push((b.to_int() % 256).to_byte())
    }
  }
  let shared = Bytes::from_array(body)
  let given = [
    @sevenz.Entry::new("one.txt", shared),
    @sevenz.Entry::new("two.txt", shared),
  ]
  let together = @sevenz.sevenz(given[:], solid=true)
  let apart = @sevenz.sevenz(given[:], solid=false)
  assert_true(together.length() < apart.length())
  assert_eq(@sevenz.un7z(together[:]).length(), 2)
  assert_eq(@sevenz.un7z(apart[:]).length(), 2)
}

///|
/// A listing reads the directory and not the data, so it needs no bound and
/// costs no decompression of the members.
test "names come out of the directory alone" {
  let archive = @sevenz.sevenz(members()[:])
  assert_eq(@sevenz.names(archive[:]), [
    "readme.txt", "data/table.csv", "logs", "blank", "naïve/grüße.txt",
  ])
}

///|
/// An archive of nothing is thirty-two bytes and reads back as nothing.
test "an empty archive is the signature header alone" {
  let archive = @sevenz.sevenz([])
  assert_eq(archive.length(), 32)
  assert_eq(@sevenz.un7z(archive[:]).length(), 0)
}

///|
/// Something that is not a 7z archive is refused by name rather than parsed as
/// one until it happens to stop.
test "a foreign file is refused" {
  let error = try {
    @sevenz.un7z(b"this is not an archive at all, not even close"[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}

///|
/// A signature header whose checksum does not cover its own fields is refused
/// before anything is allocated.
test "a damaged signature header is refused" {
  let archive = @sevenz.sevenz(members()[:])
  let spoiled : Array[Byte] = []
  for i in 0..<archive.length() {
    // One byte inside the "next header offset", which the checksum in front of it
    // is supposed to cover.
    spoiled.push(
      if i == 13 {
        (archive[i].to_int() ^ 0x01).to_byte()
      } else {
        archive[i]
      },
    )
  }
  let error = try {
    @sevenz.un7z(Bytes::from_array(spoiled)[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}

///|
/// A stream cut in half is truncated, not empty.
test "a short archive is refused" {
  let archive = @sevenz.sevenz(members()[:])
  let error = try {
    @sevenz.un7z(archive[:archive.length() - 10]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}

///|
/// The bound is what stands between a small archive and a large allocation, and
/// 7z states its unpacked sizes so it can be enforced rather than discovered.
test "an archive past the bound is refused" {
  let archive = @sevenz.sevenz(members()[:])
  let error = try {
    @sevenz.un7z(archive[:], limit=10) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=10)))
}
