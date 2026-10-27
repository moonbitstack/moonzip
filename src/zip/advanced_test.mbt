// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn members() -> Array[@zip.Entry] {
  [
    @zip.Entry::new("a.txt", b"one"),
    @zip.Entry::new("dir/b.txt", b"two two two two two two two two"),
    @zip.Entry::new("empty", b""),
  ]
}

///|
/// Walk an archive from the front, which is all a reader receiving one can do.
fn walk(
  archive : Bytes,
  password? : String,
) -> Array[String] raise @moonzip.Refused {
  let reader = @zip.Reader::new(archive[:])
  let out : Array[String] = []
  while true {
    match reader.next(password?) {
      None => break
      Some(entry) => out.push(entry.name)
    }
  }
  out
}

///|
/// A Zip64 archive reads back through both readers, and its fields say so.
test "zip64 round-trips through both readers" {
  let archive = @zip.zip(members()[:], zip64=true)
  let back = @zip.unzip(archive[:])
  assert_eq(back.length(), 3)
  assert_eq(back[0].data, b"one")
  assert_eq(back[1].data, b"two two two two two two two two")
  assert_eq(back[2].data, b"")
  // The local header of the first entry names version 4.5, and its size fields
  // are the sentinel rather than the real numbers.
  assert_eq(archive[4].to_int(), 45)
  assert_eq(archive[18].to_int(), 0xFF)
  assert_eq(archive[19].to_int(), 0xFF)
  // And the streaming reader agrees, which means the extra field is where a
  // reader expects it.
  assert_eq(walk(archive), ["a.txt", "dir/b.txt", "empty"])
}

///|
/// A data descriptor puts each member's checksum and sizes after its data, and
/// both readers still find them.
test "zip data descriptors round-trip" {
  let archive = @zip.zip(members()[:], descriptor=true)
  let back = @zip.unzip(archive[:])
  assert_eq(back[1].data, b"two two two two two two two two")
  // Bit 3 of the general-purpose flags is what says "look after the data".
  assert_eq(archive[6].to_int() & 0x08, 0x08)
  assert_eq(walk(archive), ["a.txt", "dir/b.txt", "empty"])
}

///|
/// Zip64 and descriptors together, which is what a writer streaming a file
/// larger than four gigabytes produces.
test "zip64 and descriptors together" {
  let archive = @zip.zip(members()[:], zip64=true, descriptor=true)
  assert_eq(@zip.unzip(archive[:]).map(e => e.data), [
    b"one", b"two two two two two two two two", b"",
  ])
  assert_eq(walk(archive), ["a.txt", "dir/b.txt", "empty"])
}

///|
/// A password protects every member, and the wrong password says so instead of
/// producing a decompressor error.
test "zipcrypto round-trips, and refuses the wrong password" {
  let archive = @zip.zip(members()[:], password="hunter2")
  let back = @zip.unzip(archive[:], password="hunter2")
  assert_eq(back[0].data, b"one")
  assert_eq(back[1].data, b"two two two two two two two two")
  let error = try {
    @zip.unzip(archive[:], password="hunter3") |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
  // Encrypted, so the flag says so and the streaming reader needs the password
  // as well.
  assert_eq(archive[6].to_int() & 0x01, 0x01)
  assert_eq(walk(archive, password="hunter2"), ["a.txt", "dir/b.txt", "empty"])
}

///|
/// Encryption with a descriptor is the combination a streaming writer produces:
/// the check byte comes from the time, because the header has no checksum yet.
test "zipcrypto with a data descriptor" {
  let archive = @zip.zip(members()[:], password="s3cret", descriptor=true)
  assert_eq(
    @zip.unzip(archive[:], password="s3cret")[1].data,
    b"two two two two two two two two",
  )
  assert_eq(walk(archive, password="s3cret"), ["a.txt", "dir/b.txt", "empty"])
}

///|
/// The writer builds exactly what the one-shot function builds, which is the
/// claim that lets one be defined in terms of the other.
test "the streaming writer and the one-shot agree" {
  let writer = @zip.Writer::new()
  let out : Array[Byte] = []
  for entry in members() {
    for b in writer.add(entry) {
      out.push(b)
    }
  }
  for b in writer.finish() {
    out.push(b)
  }
  assert_eq(Bytes::from_array(out), @zip.zip(members()[:]))
}

///|
/// A Zip64 archive is honest about its counts: the classic end record holds
/// sentinels, and the real numbers are in the record behind it — which is what
/// makes a reader that does not know Zip64 refuse rather than see an empty
/// archive.
test "a zip64 archive is honest about its counts" {
  let plain = @zip.zip(members()[:])
  let wide = @zip.zip(members()[:], zip64=true)
  let flat = plain.length() - 22
  let tall = wide.length() - 22
  let read16 = fn(a : Bytes, at : Int32) {
    a[at].to_int() | (a[at + 1].to_int() << 8)
  }
  assert_eq(read16(plain, flat + 10), 3)
  assert_eq(read16(wide, tall + 10), 0xFFFF)
  assert_eq(@zip.names(wide[:]).length(), 3)
}
