// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// WinZip's AES extension to APPNOTE.TXT, the AE-1 and AE-2 schemes described at
/// http://www.winzip.com/aes_info.htm.
///
/// A file's bytes are encrypted with AES in counter mode, under a key derived
/// from the password by PBKDF2-HMAC-SHA1 with a thousand iterations. The derived
/// key is split, in order, into the encryption key, the authentication key, and
/// a two-byte password-verification value. The encrypted bytes carry that salt,
/// the verification value, the ciphertext, and an HMAC-SHA1 tag truncated to
/// eighty bits. In both the local and the central header the method is 99, and
/// the method that was encrypted travels in an extra field (0x9901).
///
/// AES replaces the broken ZipCrypto as the format's real security boundary.
/// This is still not a place to store a password you cannot afford to leak, but
/// it is the difference between "anyone can read this" and "anyone who knows the
/// password can read this, and tampering is detected".

///|
/// The AES strength as its bit length: 128, 192 or 256, or 0 for "not AES".
fn aes_bits(strength : Int32) -> Int32 {
  match strength {
    1 => 128
    2 => 192
    3 => 256
    _ => 0
  }
}

///|
/// The `strength` byte the 0x9901 field carries: 1, 2 or 3.
fn aes_byte(bits : Int32) -> Int32 {
  match bits {
    128 => 1
    192 => 2
    _ => 3
  }
}

///|
/// How many bytes the encryption key (and, separately, the authentication key)
/// is, for a strength byte.
fn aes_key_len(strength : Int32) -> Int32 {
  match strength {
    1 => 16
    2 => 24
    _ => 32
  }
}

///|
/// How many bytes of salt a strength byte uses.
fn aes_salt_len(strength : Int32) -> Int32 {
  match strength {
    1 => 8
    2 => 12
    _ => 16
  }
}

///|
/// The salt for one entry.
///
/// It is derived from the name, the time, the password and the entry's offset —
/// the same deterministic recipe ZipCrypto uses for its header, so the bytes of
/// an archive do not depend on a clock or a random source and a build stays
/// reproducible. Mixing the offset in means two entries that happen to share a
/// name and a time still get distinct salts, which keeps their AES keys distinct
/// and avoids reusing one counter-mode keystream across them.
fn aes_salt(
  password : String,
  name : String,
  mtime : Int64,
  at : Int64,
  len : Int32,
) -> Bytes {
  let mut mix = @moonzip.crc32(@utf8.encode(name)[:]) ^
    @moonzip.crc32(@utf8.encode(password)[:])
  for
    part in [
      (mtime % 65536L).to_int(),
      (mtime / 65536L % 65536L).to_int(),
      (at % 65536L).to_int(),
      (at / 65536L % 65536L).to_int(),
    ] {
    mix = crc_byte(mix, (part & 0xFF).to_byte())
    mix = crc_byte(mix, ((part >> 8) & 0xFF).to_byte())
  }
  let out : Array[Byte] = []
  for i in 0..<len {
    mix = crc_byte(mix, (i * 37).to_byte())
    mix = mix * 1664525U + 1013904223U
    out.push(((mix >> 24) & 0xFFU).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A fresh SHA-1 state, as the hash factory PBKDF2 and HMAC both take.
fn sha1_hash() -> &@spec.Hash {
  @sha1.Hasher::new()
}

///|
/// Derive the key material for one entry.
///
/// PBKDF2-HMAC-SHA1 with a thousand iterations, over the password and the
/// entry's salt, produces `2 * key_len + 2` bytes: the encryption key, the
/// authentication key, and the two-byte password-verification value, in that
/// order. The verification value is the wrong-password tripwire a reader checks
/// before it spends time on the authentication tag.
fn aes_derive(
  password : String,
  salt : BytesView,
  strength : Int32,
) -> (Bytes, UInt32) {
  let klen = aes_key_len(strength)
  let total = klen * 2 + 2
  let material = @pbkdf2.key(
    @utf8.encode(password)[:],
    salt,
    sha1_hash,
    rounds=1000,
    len=total,
  )
  let pv0 = material[total - 2].to_uint()
  let pv1 = material[total - 1].to_uint()
  let pv = (pv0 << 8) | pv1
  (material, pv)
}

///|
/// The initial counter block.
///
/// WinZip AES starts the counter at one, in the most significant byte of the
/// sixteen-byte block; every block after increments the low byte. The same
/// convention Go's `crypto/cipher` and 7-Zip use, which is what makes an archive
/// written here open there.
fn aes_nonce() -> Bytes {
  let out : Array[Byte] = [b'\x01']
  for _ in 1..<16 {
    out.push(b'\x00')
  }
  Bytes::from_array(out)
}

///|
/// Encrypt `data` under `password` with WinZip AES.
///
/// `strength` is 128, 192 or 256. Returns the bytes that go where the payload
/// used to: salt, verification value, ciphertext, authentication tag. The AE-1
/// versus AE-2 choice belongs to the writer, because it is a choice about the
/// CRC in the header rather than about the ciphertext.
pub fn aes_encrypt(
  data : BytesView,
  password : String,
  name : String,
  mtime : Int64,
  at : Int64,
  strength~ : Int32 = 256,
) -> Bytes {
  let s = aes_byte(strength)
  let salt = aes_salt(password, name, mtime, at, aes_salt_len(s))
  let (material, pv) = aes_derive(password, salt[:], s)
  let klen = aes_key_len(s)
  let enc = material[0:klen]
  let auth = material[klen:klen + klen]
  let cipher = try @aes.Cipher::new(enc) catch {
    _ => abort("zip: an AES key of the wrong length")
  } noraise {
    c => c
  }
  let ctr = try @mode.Ctr::new(cipher, aes_nonce()[:]) catch {
    _ => abort("zip: the AES counter was refused")
  } noraise {
    m => m
  }
  let cipher_text = ctr.apply(data)
  let mac = @hmac.Hmac::new(auth, sha1_hash)
  mac.write(cipher_text[:])
  let tag = mac.finish()
  let out : Array[Byte] = []
  for b in salt {
    out.push(b)
  }
  out.push(((pv >> 8) & 0xFFU).to_byte())
  out.push((pv & 0xFFU).to_byte())
  for b in cipher_text {
    out.push(b)
  }
  for i in 0..<10 {
    out.push(tag[i])
  }
  Bytes::from_array(out)
}

///|
/// Whether two authentication tags agree, as a constant-time-ish comparison of
/// the ten bytes that matter.
fn aes_tag_ok(want : BytesView, seen : BytesView) -> Bool {
  if seen.length() != 10 {
    return false
  }
  let mut diff = 0
  for i in 0..<10 {
    diff = diff | (want[i].to_int() ^ seen[i].to_int())
  }
  diff == 0
}

///|
/// Decrypt what [`aes_encrypt`](#aes_encrypt) wrote.
///
/// The salt names the key, the verification value rejects a wrong password
/// before any ciphertext is touched, and the authentication tag is checked
/// before the bytes are handed back — a truncated HMAC is a message authentication
/// code, and skipping it would turn a tampered archive into a silent
/// decompression error three layers down.
pub fn aes_decrypt(
  data : BytesView,
  password : String,
  strength : Int32,
) -> Bytes raise @moonzip.Refused {
  let s = aes_byte(strength)
  let salt_len = aes_salt_len(s)
  let klen = aes_key_len(s)
  guard data.length() >= salt_len + 2 + 10 else {
    raise @moonzip.Header(at=0, what="an AES entry shorter than its overhead")
  }
  let salt = data[0:salt_len]
  let seen_pv = (data[salt_len].to_uint() << 8) | data[salt_len + 1].to_uint()
  let cipher_len = data.length() - salt_len - 2 - 10
  let cipher_text = data[salt_len + 2:salt_len + 2 + cipher_len]
  let tag = data[salt_len + 2 + cipher_len:data.length()]
  let (material, pv) = aes_derive(password, salt, s)
  guard seen_pv == pv else {
    raise @moonzip.Header(
      at=salt_len,
      what="the password does not decrypt this entry",
    )
  }
  let enc = material[0:klen]
  let auth = material[klen:klen + klen]
  let mac = @hmac.Hmac::new(auth, sha1_hash)
  mac.write(cipher_text)
  let want = mac.finish()
  guard aes_tag_ok(want[:], tag) else {
    raise @moonzip.Header(
      at=salt_len + 2 + cipher_len,
      what="the AES authentication tag does not match",
    )
  }
  let cipher = try @aes.Cipher::new(enc) catch {
    _ => abort("zip: an AES key of the wrong length")
  } noraise {
    c => c
  }
  let ctr = try @mode.Ctr::new(cipher, aes_nonce()[:]) catch {
    _ => abort("zip: the AES counter was refused")
  } noraise {
    m => m
  }
  ctr.apply(cipher_text)
}

///|
/// Read the 0x9901 field of an entry's extra data, which is where an AES entry
/// says which strength it used and which method it encrypted.
///
/// Returns whether the field was present, the real method, the strength byte,
/// and the AE version (1 or 2). An AES entry without this field is malformed.
fn aes_info(extra : BytesView) -> (Bool, Int32, Int32, Int32) {
  let mut at = 0
  while at + 4 <= extra.length() {
    let id = read16(extra, at)
    let len = read16(extra, at + 2)
    if id == 0x9901 && at + 4 + 7 <= extra.length() {
      let version = read16(extra, at + 4)
      let strength = extra[at + 8].to_int()
      let actual = read16(extra, at + 9)
      return (true, actual, strength, version)
    }
    at += 4 + len
  }
  (false, 0, 0, 0)
}
