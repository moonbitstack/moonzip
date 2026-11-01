// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A spanned archive reads back the members that went in, across several disks.
test "spanned volumes round-trip" {
  let entries = [
    @zip.Entry::new("a.txt", b"one"),
    @zip.Entry::new("b.txt", b"two two two"),
    @zip.Entry::new("c/d.txt", b"three three three"),
  ]
  let volumes = @zip.zip_spanned(entries[:], 48)
  assert_true(volumes.length() > 1)
  let back = @zip.unzip_spanned(volumes)
  assert_eq(back.map(e => e.data), [
    b"one", b"two two two", b"three three three",
  ])
}

///|
/// With one disk the spanned form is byte-for-byte the ordinary archive: the
/// disk fields are zero and the offsets are already absolute.
test "a one-disk spanned archive is the ordinary archive" {
  let entries = [@zip.Entry::new("a.txt", b"hello")]
  let normal = @zip.zip(entries[:])
  let volumes = @zip.zip_spanned(entries[:], 1 << 20)
  assert_eq(volumes.length(), 1)
  assert_eq(volumes[0], normal)
}

///|
/// Every volume but the last is exactly the requested size.
test "every volume but the last is full" {
  let entries = [
    @zip.Entry::new(
      "x",
      Bytes::from_array(Array::make(500, b'a')),
      kind=@zip.Kind::Stored,
    ),
  ]
  let volumes = @zip.zip_spanned(entries[:], 100)
  assert_true(volumes.length() > 1)
  for i in 0..<volumes.length() {
    if i + 1 < volumes.length() {
      assert_eq(volumes[i].length(), 100)
    }
  }
}

///|
/// The end record names the last disk, which is what makes this spanned rather
/// than a byte split: `split` would have left every disk number at zero.
test "the end record names the last disk" {
  let entries = [
    @zip.Entry::new(
      "x",
      Bytes::from_array(Array::make(600, b'a')),
      kind=@zip.Kind::Stored,
    ),
  ]
  let volumes = @zip.zip_spanned(entries[:], 100)
  assert_true(volumes.length() > 1)
  let joined = @zip.join(volumes)
  let end = joined.length() - 22
  let disk = joined[end + 4].to_int() | (joined[end + 5].to_int() << 8)
  assert_eq(disk, volumes.length() - 1)
}

///|
/// A member that begins near a volume boundary — its local header or its data
/// crossing from one disk into the next — still reads back, because the reader
/// joins the disks before it follows any offset.
test "a member across a boundary reads back" {
  let big = Bytes::from_array(Array::make(900, b'z'))
  let entries = [@zip.Entry::new("big.bin", big, kind=@zip.Kind::Stored)]
  let volumes = @zip.zip_spanned(entries[:], 64)
  assert_true(volumes.length() > 3)
  let back = @zip.unzip_spanned(volumes)
  assert_eq(back[0].data, big)
}

///|
/// Spanned volumes compose with AES: the member is encrypted, then its offset is
/// rewritten to a disk coordinate, and the reader still has the password to open
/// it.
test "spanned volumes carry an encrypted member" {
  let entries = [
    @zip.Entry::new("s.txt", b"secret payload", kind=@zip.Kind::Stored),
  ]
  let volumes = @zip.zip_spanned(entries[:], 40, password="pw", aes=256)
  assert_true(volumes.length() > 1)
  let back = @zip.unzip_spanned(volumes, password="pw")
  assert_eq(back[0].data, b"secret payload")
}

///|
/// An empty archive is one disk of nothing but the end record.
test "an empty archive spans to one volume" {
  let volumes = @zip.zip_spanned([][:], 64)
  assert_eq(volumes.length(), 1)
  assert_eq(@zip.unzip_spanned(volumes), [])
}
