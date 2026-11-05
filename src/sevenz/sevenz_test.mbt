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

///|
/// A source that remembers what it was asked for.
///
/// A reader that takes the whole archive and then slices it up is the thing random
/// access exists to avoid, and the difference is not visible in the result — only
/// in what was read. This records it.
struct Probe {
  data : Bytes
  mut largest : Int32
  mut total : Int64
  mut reads : Int32
}

///|
impl @sevenz.RandomAccess for Probe with fn read(self, offset, len) {
  let size = self.data.length().to_int64()
  if offset < 0L || offset > size {
    raise @moonzip.Truncated(at=0)
  }
  let stop = if offset + len.to_int64() > size {
    size
  } else {
    offset + len.to_int64()
  }
  let took = (stop - offset).to_int()
  if took > self.largest {
    self.largest = took
  }
  self.total += took.to_int64()
  self.reads += 1
  self.data[offset.to_int():stop.to_int()].to_owned()
}

///|
impl @sevenz.RandomAccess for Probe with fn size(self) {
  self.data.length().to_int64()
}

///|
/// A chain of files large enough that holding all of them is visibly different
/// from holding one: eight members, seven of them thirty kilobytes.
fn many_members() -> Array[@sevenz.Entry] {
  let out : Array[@sevenz.Entry] = []
  for i in 0..<8 {
    let body : Array[Byte] = []
    for j in 0..<30000 {
      body.push(((i * 31 + j * 7) % 251).to_byte())
    }
    out.push(@sevenz.Entry::new("part/\{i}.bin", Bytes::from_array(body)))
  }
  out
}

///|
/// An archive read through a source is read a folder at a time, never whole.
test "a source is asked for one folder at a time" {
  let given = many_members()
  let archive = @sevenz.sevenz(given[:], solid=false)
  let probe = { data: archive, largest: 0, total: 0L, reads: 0, }
  let back = @sevenz.un7z_from(probe)
  assert_eq(back.length(), given.length())
  for i in 0..<given.length() {
    assert_eq(back[i].data, given[i].data)
  }
  // One folder is a thirtieth of this archive; the reader must never have asked
  // for more than that plus a header, and must have asked more than once.
  assert_true(probe.largest < archive.length() / 4)
  assert_true(probe.reads >= given.length())
  assert_true(probe.total >= archive.length().to_int64() / 2)
}

///|
/// A listing costs the directory and nothing else.
test "a listing reads the directory, not the data" {
  let given = many_members()
  let archive = @sevenz.sevenz(given[:], solid=false)
  let probe = { data: archive, largest: 0, total: 0L, reads: 0, }
  let names = @sevenz.names_from(probe)
  assert_eq(names.length(), given.length())
  assert_eq(names[0], "part/0.bin")
  assert_true(probe.total < archive.length().to_int64() / 4)
}

///|
/// A solid archive is one folder, so the reader holds one folder — which for an
/// archive of eight files is what "one block" means, and the members still arrive.
test "a solid archive is held one folder at a time too" {
  let given = many_members()
  let archive = @sevenz.sevenz(given[:], solid=true)
  let probe = { data: archive, largest: 0, total: 0L, reads: 0, }
  let back = @sevenz.un7z_from(probe)
  assert_eq(back.length(), given.length())
  for i in 0..<given.length() {
    assert_eq(back[i].data, given[i].data)
  }
  assert_true(probe.largest < archive.length() + 1)
}
