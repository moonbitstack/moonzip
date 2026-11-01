// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Cutting an archive at boundaries and putting it back gives the same bytes,
/// and every volume but the last is exactly the requested size.
test "volumes join back to the archive" {
  let archive = @zip.zip([@zip.Entry::new("a.txt", b"hello world")][:])
  let parts = @zip.split(archive[:], 10)
  assert_true(parts.length() > 1)
  for i in 0..<parts.length() {
    if i + 1 < parts.length() {
      assert_eq(parts[i].length(), 10)
    } else {
      assert_true(parts[i].length() <= 10)
    }
  }
  assert_eq(@zip.join(parts), archive)
}

///|
/// A split archive reads back to the same members, because joining the volumes
/// is the archive and reading it is the ordinary path.
test "a split archive reads back" {
  let entries = [
    @zip.Entry::new("a.txt", b"one"),
    @zip.Entry::new("b.txt", b"two two two"),
  ]
  let volumes = @zip.zip_split(entries[:], 16)
  assert_true(volumes.length() > 1)
  let back = @zip.unzip_split(volumes)
  assert_eq(back.length(), 2)
  assert_eq(back[0].data, b"one")
  assert_eq(back[1].data, b"two two two")
}

///|
/// The names are the convention tools expect: numbered `.z01` volumes and a
/// final `.zip`, with a single volume being just `.zip`.
test "volume names follow the convention" {
  assert_eq(@zip.volume_names("archive", 1), ["archive.zip"])
  assert_eq(
    @zip.volume_names("archive", 3),
    ["archive.z01", "archive.z02", "archive.zip"],
  )
  assert_eq(
    @zip.volume_names("archive", 11),
    [
      "archive.z01", "archive.z02", "archive.z03", "archive.z04", "archive.z05",
      "archive.z06", "archive.z07", "archive.z08", "archive.z09", "archive.z10",
      "archive.zip",
    ],
  )
}

///|
/// A one-byte volume is the worst case and still reassembles, which is the
/// property that makes "split" a function of the size and nothing else.
test "a one-byte volume still reassembles" {
  let archive = @zip.zip([@zip.Entry::new("x", b"y")][:])
  let parts = @zip.split(archive[:], 1)
  assert_eq(parts.length(), archive.length())
  assert_eq(@zip.join(parts), archive)
  assert_eq(@zip.unzip_split(parts)[0].data, b"y")
}

///|
/// Splitting an encrypted archive keeps the encryption intact: the volumes are
/// just bytes, and reading them back still needs the password.
test "an encrypted archive splits and reads back" {
  let entry = @zip.Entry::new("s.txt", b"secret payload", kind=@zip.Kind::Stored)
  let volumes = @zip.zip_split([entry][:], 12, password="pw", aes=256)
  assert_true(volumes.length() > 1)
  let back = @zip.unzip_split(volumes, password="pw")
  assert_eq(back[0].data, b"secret payload")
}
