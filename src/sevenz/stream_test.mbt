// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The members the streaming tests hand a writer: one file with content, one
/// with none, a directory, and a name that only survives as UTF-16.
fn stream_members() -> Array[@sevenz.Entry] {
  [
    @sevenz.Entry::new(
      "first.txt",
      b"the first member, a line of text to compress\n",
      mtime=1700000000L,
    ),
    @sevenz.Entry::new("dir/second.txt", b"the second member\n"),
    @sevenz.Entry::directory("dir/empty"),
    @sevenz.Entry::new("zero", b""),
    @sevenz.Entry::new("naïve.txt", b"an umlaut\n"),
  ]
}

///|
/// The archive a streaming writer produces, assembled in the order the format
/// asks for: the signature header, then the folders, then the directory.
fn assemble(writer : @sevenz.Writer, entries : Array[@sevenz.Entry]) -> Bytes {
  let body : Array[Byte] = []
  for entry in entries {
    for b in writer.add(entry) {
      body.push(b)
    }
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
/// What one archive decodes to, as names and data, so two archives can be
/// compared without comparing their bytes.
fn listing(entries : Array[@sevenz.Entry]) -> Array[String] {
  let out : Array[String] = []
  for entry in entries {
    out.push(
      "\{entry.name}:\{entry.data.length()}:\{@moonzip.crc32(entry.data[:])}",
    )
  }
  out
}

///|
/// Every method and both folder layouts: what the streaming writer builds is
/// what the one-shot writer builds, member for member.
test "the streaming writer writes what the one-shot writer writes" {
  for how in [@sevenz.Method::Copy, @sevenz.Method::Lzma, @sevenz.Method::Lzma2] {
    for solid in [true, false] {
      let given = stream_members()
      let one_shot = @sevenz.sevenz(given[:], how~, solid~)
      let streamed = assemble(@sevenz.Writer::new(how~, solid~), given)
      assert_eq(
        listing(@sevenz.un7z(streamed[:])),
        listing(@sevenz.un7z(one_shot[:])),
      )
      assert_eq(@sevenz.names(streamed[:]), @sevenz.names(one_shot[:]))
    }
  }
}

///|
/// A solid folder holds every member with data; a non-solid archive gives each
/// one a folder of its own. The directory says which, and the count is what a
/// reader would use to decide how much it has to decode to reach the last
/// member.
test "solid puts every member in one folder" {
  let given = stream_members()
  let together = assemble(@sevenz.Writer::new(how=@sevenz.Method::Lzma), given)
  let apart = assemble(
    @sevenz.Writer::new(how=@sevenz.Method::Lzma, solid=false),
    given,
  )
  // Three of the five members have data, so a solid archive is one folder of
  // three streams and the other is three folders of one.
  assert_eq(listing(@sevenz.un7z(together[:])), listing(@sevenz.un7z(apart[:])))
  assert_true(together.length() < apart.length())
}

///|
/// An archive with no members is the signature header and nothing else, which is
/// what 7-Zip writes for one.
test "an empty stream leaves the archive at the signature header" {
  let writer = @sevenz.Writer::new()
  let tail = writer.finish()
  let start = writer.signature()
  assert_eq(start.length(), 32)
  assert_eq(tail.length(), 0)
}

///|
/// The directory's position is the length of the packed data, so a writer that
/// has not finished cannot say where it is. Asking early is a bug in the caller,
/// and a stream that is silently wrong is worse than a stop.
test "panic the signature is not known before the archive is finished" {
  let writer = @sevenz.Writer::new()
  writer.add(@sevenz.Entry::new("a.txt", b"a")) |> ignore
  writer.signature() |> ignore
}

///|
/// The reader takes the archive in pieces of any size and produces the same
/// members every time. One byte at a time is the case that matters: a boundary
/// can fall inside the signature header, inside a packed stream, or inside the
/// directory, and none of those is a place a reader may misread.
test "the reader takes the archive in any chunk size" {
  let given = stream_members()
  let archive = assemble(@sevenz.Writer::new(), given)
  let want = listing(@sevenz.un7z(archive[:]))
  for step in [1, 2, 3, 7, 64, 511, 4096, 65536] {
    let reader = @sevenz.Reader::new()
    let mut at = 0
    while at < archive.length() {
      let stop = if archive.length() - at < step {
        archive.length()
      } else {
        at + step
      }
      reader.push(archive[at:stop])
      at = stop
    }
    assert_eq(listing(reader.finish()), want)
  }
}

///|
/// Archives 7-Zip wrote, read a piece at a time. The pinned bytes are the ones
/// `interop_test` pins, so this is the same check with the reader that takes its
/// input as it arrives rather than all at once.
test "a 7-Zip archive reads back in pieces" {
  let archives = [
    ("empty", pinned_empty_7z()),
    ("lzma", pinned_lzma_1_7z()),
    ("copy", pinned_copy_7z()),
    ("deflate", pinned_deflate_7z()),
    ("lzma2", pinned_lzma2delta_1_7z()),
    ("solid", pinned_umlaut_solid_7z()),
  ]
  for case in archives {
    let (name, archive) = case
    let want = listing(@sevenz.un7z(archive[:]))
    for step in [1, 5, 4096] {
      let reader = @sevenz.Reader::new()
      let mut at = 0
      while at < archive.length() {
        let stop = if archive.length() - at < step {
          archive.length()
        } else {
          at + step
        }
        reader.push(archive[at:stop])
        at = stop
      }
      assert_eq(listing(reader.finish()), want, msg=name)
    }
  }
}

///|
/// A file that is not a 7z archive is refused on its first six bytes rather than
/// after the caller has fed it a gigabyte.
test "the reader refuses a signature it does not know, early" {
  let reader = @sevenz.Reader::new()
  let refused = try {
    reader.push(b"not a 7z archive")
    false
  } catch {
    @moonzip.Header(at=_, what=_) => true
    _ => false
  }
  assert_true(refused)
}

///|
/// The bound the one-shot reader takes is the bound the streaming one takes.
test "the streaming reader is bounded" {
  let archive = assemble(@sevenz.Writer::new(), [
    @sevenz.Entry::new("big.txt", Bytes::make(70000, b'a')),
  ])
  let reader = @sevenz.Reader::new(limit=1000)
  reader.push(archive[:])
  let refused = try {
    reader.finish() |> ignore
    false
  } catch {
    @moonzip.TooBig(limit=_) => true
    _ => false
  }
  assert_true(refused)
}
