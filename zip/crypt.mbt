// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The traditional PKWARE encryption, which APPNOTE.TXT §6.1 calls "traditional
/// PKWARE encryption" and everybody else calls ZipCrypto.
///
/// It is a stream cipher built out of CRC-32: three 32-bit keys, each byte of
/// plaintext folding into all three, and one byte of keystream per byte of
/// input. It is also thoroughly broken — a known-plaintext attack recovers the
/// keys from a dozen bytes — which is why APPNOTE.TXT now specifies AES in its
/// place. It exists here because archives in the wild still carry it, and
/// opening one should not need a second tool.
///
/// This is not a security boundary and nothing in this package will claim it is.
priv struct Keys {
  mut k0 : UInt32
  mut k1 : UInt32
  mut k2 : UInt32
}

///|
fn Keys::new() -> Keys {
  { k0: 0x12345678U, k1: 0x23456789U, k2: 0x34567890U, }
}

///|
/// One byte into a CRC-32 state, without the usual pre- and post-complement —
/// the form this cipher uses, and the reason it is not quite "the CRC of the
/// data".
fn crc_byte(state : UInt32, byte : Byte) -> UInt32 {
  let mut c = state ^ byte.to_uint()
  for _ in 0..<8 {
    c = if (c & 1U) != 0U { (c >> 1) ^ 0xEDB88320U } else { c >> 1 }
  }
  c
}

///|
fn Keys::update(self : Keys, byte : Byte) -> Unit {
  self.k0 = crc_byte(self.k0, byte)
  self.k1 = (self.k1 + (self.k0 & 0xFFU)) * 134775813U + 1U
  self.k2 = crc_byte(self.k2, (self.k1 >> 24).to_byte())
}

///|
/// One byte of keystream. The odd multiply is the whole cipher: it depends on
/// every bit of `k2`, it is three instructions, and it was designed when the
/// threat model was "my brother cannot read my homework".
fn Keys::stream(self : Keys) -> Byte {
  let temp = self.k2 | 2U
  (((temp * (temp ^ 1U)) >> 8) & 0xFFU).to_byte()
}

///|
fn Keys::of(password : String) -> Keys {
  let keys = Keys::new()
  for b in password {
    keys.update((b.to_int() & 0xFF).to_byte())
  }
  keys
}

///|
/// The eleven bytes of the encryption header that exist to be different every
/// time.
///
/// They come from a hash of the name, the time and the password rather than
/// from a random source: a library that wrote random bytes would give different
/// output for the same input, and a build that is not reproducible is a build
/// whose archives cannot be compared. ZipCrypto offers no security either way,
/// so nothing is lost — a caller who needs a real boundary needs AES.
fn secret_prefix(
  password : String,
  name : String,
  mtime : Int64,
) -> Array[Byte] {
  let mut mix = @moonzip.crc32(@utf8.encode(name)[:]) ^
    @moonzip.crc32(@utf8.encode(password)[:])
  // The low four bytes of the time, folded in one byte at a time — shifting an
  // Int64 is not something this language makes cheap, and a division is.
  let low = (mtime % 65536L).to_int()
  let high = (mtime / 65536L % 65536L).to_int()
  for part in [low, high] {
    mix = crc_byte(mix, (part & 0xFF).to_byte())
    mix = crc_byte(mix, ((part >> 8) & 0xFF).to_byte())
  }
  let out : Array[Byte] = []
  for i in 0..<11 {
    mix = crc_byte(mix, (i * 37).to_byte())
    mix = mix * 1664525U + 1013904223U
    out.push(((mix >> 24) & 0xFFU).to_byte())
  }
  out
}

///|
/// Encrypt `data` under `password`.
///
/// `check` is the byte a reader compares after decrypting the header: the high
/// byte of the CRC-32, or — when the entry's sizes are in a data descriptor
/// rather than its local header — the high byte of the MS-DOS time. The caller
/// knows which, because the caller owns the flags.
pub fn zipcrypt_encrypt(
  data : BytesView,
  password : String,
  name : String,
  mtime : Int64,
  check : Byte,
) -> Bytes {
  let keys = Keys::of(password)
  let out : Array[Byte] = []
  for b in secret_prefix(password, name, mtime) {
    let k = keys.stream()
    keys.update(b)
    out.push((b.to_int() ^ k.to_int()).to_byte())
  }
  let k = keys.stream()
  keys.update(check)
  out.push((check.to_int() ^ k.to_int()).to_byte())
  for b in data {
    let k = keys.stream()
    keys.update(b)
    out.push((b.to_int() ^ k.to_int()).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Decrypt what [`zipcrypt_encrypt`](#zipcrypt_encrypt) wrote.
///
/// The check byte is compared before any of the body is handed back, so a wrong
/// password says so instead of turning into a decompressor error three layers
/// further in — which is the difference between "you typed the password wrong"
/// and "this archive is damaged".
pub fn zipcrypt_decrypt(
  data : BytesView,
  password : String,
  check : Byte,
) -> Bytes raise @moonzip.Refused {
  guard data.length() >= 12 else { raise @moonzip.Truncated(at=data.length()) }
  let keys = Keys::of(password)
  let out : Array[Byte] = []
  for i in 0..<12 {
    let k = keys.stream()
    let plain = (data[i].to_int() ^ k.to_int()).to_byte()
    keys.update(plain)
    if i == 11 {
      if plain != check {
        raise @moonzip.Header(
          at=11,
          what="the password does not decrypt this entry",
        )
      }
    }
  }
  for i in 12..<data.length() {
    let k = keys.stream()
    let plain = (data[i].to_int() ^ k.to_int()).to_byte()
    out.push(plain)
    keys.update(plain)
  }
  Bytes::from_array(out)
}
