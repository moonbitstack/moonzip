// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Build archives and read them back.
///
///     moon run examples/archive
///
/// Both containers are directories that are files, and both are written here the
/// same way: hand the writer members, take the bytes it produces, hand them back
/// to a reader that was told nothing about them.
fn members() -> Array[@zip.Entry] {
  [
    @zip.Entry::new(
      "readme.txt",
      b"a member of an archive\n",
      mtime=1700000000L,
    ),
    @zip.Entry::new("data/table.csv", b"name,size\nreadme,24\n"),
    @zip.Entry::new("data/already-gzipped.png", Bytes::make(600, b'\x89')),
  ]
}

///|
fn main raise {
  let entries = members()

  let plain = @zip.zip(entries[:])
  println(
    "zip: \{plain.length()} bytes, \{@zip.names(plain[:]).length()} members",
  )

  // The same archive in the wide form: sixty-four-bit sizes and offsets, for a
  // member or an archive that outgrew the thirty-two-bit fields.
  let wide = @zip.zip(entries[:], zip64=true)
  println("zip64: \{wide.length()} bytes")

  // With a data descriptor: each member's sizes follow its data rather than
  // preceding it, which is what a writer that has not finished reading must do.
  let streamed = @zip.zip(entries[:], descriptor=true)
  println("with descriptors: \{streamed.length()} bytes")

  // And encrypted, with the cipher the format called encryption for fifteen
  // years. Not a security boundary; see the `zip` documentation.
  let locked = @zip.zip(entries[:], password="moonzip")
  let opened = @zip.unzip(locked[:], password="moonzip")
  println(
    "with a password: \{locked.length()} bytes, readable: \{opened[0].data == entries[0].data}",
  )
  let refused = try {
    @zip.unzip(locked[:], password="wrong") |> ignore
    "no"
  } catch {
    _ => "yes"
  }
  println("the wrong password is refused: \{refused}")

  // Reading from the front, which is all a reader receiving an archive can do.
  let reader = @zip.Reader::new(plain[:])
  let seen : Array[String] = []
  while true {
    match reader.next() {
      None => break
      Some(entry) => seen.push(entry.name)
    }
  }
  let walked = StringBuilder()
  let mut first_one = true
  for name in seen {
    if !first_one {
      walked.write_string(", ")
    }
    first_one = false
    walked.write_string(name)
  }
  println("walked from the front: \{walked}")

  // tar is the other half of the same idea, without the compressed members: one
  // header per file, then the bytes. A tarball is that archive through gzip.
  let files = [
    @tar.Entry::new(
      "readme.txt",
      b"a member of an archive\n",
      mtime=1700000000L,
    ),
    @tar.Entry::new("data/table.csv", b"name,size\nreadme,24\n"),
    @tar.Entry::directory("empty"),
    @tar.Entry::symlink("latest", "readme.txt"),
  ]
  let tarball = @tar.tar(files[:])
  println("tar: \{tarball.length()} bytes")
  let gzipped = @tar.targz(files[:])
  println("tar.gz: \{gzipped.length()} bytes")
  let back = @tar.untargz(gzipped[:])
  let listed = StringBuilder()
  let mut leading = true
  for entry in back {
    if !leading {
      listed.write_string(", ")
    }
    leading = false
    listed.write_string(entry.name)
  }
  println("read back: \{listed}")
  println("the symlink survived: \{back[3].link}")
}
