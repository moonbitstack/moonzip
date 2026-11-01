// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A fresh SHA-1 state, as the hash factory PBKDF2 and HMAC both take.
fn sha1_factory() -> &@spec.Hash {
  @sha1.Hasher::new()
}

///|
/// An AES key schedule, or a failed test.
fn aes_ctx(key : BytesView) -> @aes.Cipher {
  try @aes.Cipher::new(key) catch {
    _ => abort("bad test key")
  } noraise {
    c => c
  }
}

///|
/// PBKDF2-HMAC-SHA1 against the RFC 6070 cases, which pin the iteration count
/// and the block counter before anything WinZip-specific is layered on top.
test "pbkdf2-hmac-sha1 matches RFC 6070" {
  let one = @pbkdf2.key(
    b"password"[:],
    b"salt"[:],
    sha1_factory,
    rounds=1,
    len=20,
  )
  assert_eq(@base16.encode(one), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
  let two = @pbkdf2.key(
    b"password"[:],
    b"salt"[:],
    sha1_factory,
    rounds=2,
    len=20,
  )
  assert_eq(@base16.encode(two), "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
  let many = @pbkdf2.key(
    b"password"[:],
    b"salt"[:],
    sha1_factory,
    rounds=4096,
    len=20,
  )
  assert_eq(@base16.encode(many), "4b007901b765489abead49d926f721d065a429c1")
}

///|
/// The published WinZip AES known-answer vector, decrypted with the published
/// key: `Hello World\r\n` under a 256-bit key must produce the exact ciphertext
/// and tag another implementation wrote. This is what pins the one WinZip-
/// specific choice — that the counter starts at one in the high byte of the
/// block, which is the convention Go, 7-Zip and WinZip share.
test "the published WinZip AES vector" {
  let enc_key = @base16.decode_lossy(
    "8d11d79d63e5d18904ae6acb77cfed5579912f8bc321063ba9d607f709af372a",
  )
  let auth_key = @base16.decode_lossy(
    "6fa064bf1816d83a802855a4e812286f9f47c60698fe61fe4ba12a0b759520ee",
  )
  let nonce = @base16.decode_lossy("01000000000000000000000000000000")
  let plain = @utf8.encode("Hello World\r\n")
  let cipher_text = @mode.Ctr::new(aes_ctx(enc_key[:]), nonce[:]).apply(
    plain[:],
  )
  assert_eq(@base16.encode(cipher_text), "e0ba876cd116a6df91cf7f8a14")
  // The tag is HMAC-SHA1 over the ciphertext, truncated to eighty bits.
  let tag = @hmac.mac(auth_key[:], cipher_text[:], sha1_factory)
  assert_eq(@base16.encode(tag[0:10]), "b89f23e399cb17d5651a")
}

///|
/// An archive encrypted at every strength and every AE version comes back.
/// AE-1 keeps the CRC and AE-2 zeroes it, but either way the bytes and the name
/// are the ones that went in.
test "aes round-trips at every strength and AE version" {
  let data = @utf8.encode("the quick brown fox jumps over the lazy dog")
  for strength in [128, 192, 256] {
    for ae in [1, 2] {
      let entry = @zip.Entry::new("note.txt", data, kind=@zip.Kind::Stored)
      let archive = @zip.zip(
        [entry][:],
        password="correct horse battery",
        aes=strength,
        ae~,
      )
      let back = @zip.unzip(archive[:], password="correct horse battery")
      assert_eq(back[0].data, data)
    }
  }
}

///|
/// AES layers over DEFLATE: the member is compressed first and then encrypted,
/// and a reader expands it back after decrypting.
test "aes over deflate" {
  let data = Bytes::from_array(Array::make(4000, b'a'))
  let entry = @zip.Entry::new("runs.txt", data, kind=@zip.Kind::Deflated)
  let archive = @zip.zip([entry][:], password="pw", aes=256)
  let back = @zip.unzip(archive[:], password="pw")
  assert_eq(back[0].data, data)
  // The archive is smaller than storing every byte, so the deflate survived
  // the encryption rather than being bypassed.
  assert_true(archive.length() < data.length())
}

///|
/// Without a password an AES entry is refused, and with the wrong one it is
/// refused too — the verification value is the tripwire.
test "aes refuses a wrong password" {
  let entry = @zip.Entry::new("s.txt", b"secret", kind=@zip.Kind::Stored)
  let archive = @zip.zip([entry][:], password="right", aes=256)
  try @zip.unzip(archive[:], password="wrong") |> ignore catch {
    e => assert_true(e is @moonzip.Header(_))
  } noraise {
    _ => fail("a wrong password was accepted")
  }
  try @zip.unzip(archive[:]) |> ignore catch {
    e => assert_true(e is @moonzip.Header(_))
  } noraise {
    _ => fail("an AES entry was read with no password")
  }
}

///|
/// A flipped byte in the ciphertext is caught by the authentication tag before
/// it becomes a decompression error three layers down.
test "aes refuses a tampered payload" {
  let payload = @zip.aes_encrypt(
    b"top secret message"[:],
    "pw",
    "x",
    0L,
    0L,
    strength=256,
  )
  let bad = payload.to_array()
  // Past the sixteen-byte salt and the two-byte verification value is the
  // ciphertext; changing it must break the tag.
  bad[20] = (bad[20].to_int() ^ 0xFF).to_byte()
  try @zip.aes_decrypt(Bytes::from_array(bad)[:], "pw", 256) |> ignore catch {
    e => assert_true(e is @moonzip.Header(_))
  } noraise {
    _ => fail("a tampered payload was accepted")
  }
}

///|
/// Listing an AES archive does not need the password: the central directory is
/// plain text, and only the members are encrypted.
test "aes names come out without a password" {
  let archive = @zip.zip(
    [@zip.Entry::new("a.txt", b"x"), @zip.Entry::new("b.txt", b"y")][:],
    password="pw",
    aes=256,
  )
  assert_eq(@zip.names(archive[:]), ["a.txt", "b.txt"])
}

///|
/// Two entries with the same name and time still get distinct salts, because the
/// salt folds in the entry's offset. Distinct salts mean distinct keys, so the
/// counter mode never reuses one keystream across two members.
test "same-named entries get distinct ciphertexts" {
  let entry = @zip.Entry::new(
    "same.txt",
    b"identical content",
    kind=@zip.Kind::Stored,
  )
  let archive = @zip.zip([entry, entry][:], password="pw", aes=256)
  let back = @zip.unzip(archive[:], password="pw")
  assert_eq(back.length(), 2)
  assert_eq(back[0].data, b"identical content")
  assert_eq(back[1].data, b"identical content")
  // The two payloads must not be byte-identical, or the keystream repeated.
  let first = @zip.aes_encrypt(
    b"identical content"[:],
    "pw",
    "same.txt",
    0L,
    0L,
  )
  let second = @zip.aes_encrypt(
    b"identical content"[:],
    "pw",
    "same.txt",
    0L,
    40L,
  )
  assert_not_eq(first, second)
}
