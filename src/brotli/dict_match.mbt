// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Finding the static dictionary's words in the text being compressed.
///
/// A dictionary reference is not a back-reference: the distance is larger than
/// the window, and what it addresses is `(transform, word)` inside the 122 KB
/// blob rather than a byte of the output. So the encoder has to answer a
/// different question from the one a match finder answers — not "where did I see
/// these bytes before" but "is this one of the words the format already knows" —
/// and the answer has to come with the word's length, which is also the copy's
/// length.
///
/// The index here is over first four bytes and is built once per `compress` call:
/// thirteen thousand words hashed into sixty-five thousand buckets, then a walk
/// down one chain per position. Four bytes because a dictionary reference shorter
/// than four is not representable.
const DICT_HASH_BITS : Int32 = 16

///|
/// The transforms this writer can reach.
///
/// Every transform is a prefix, a kind, and a suffix. Three shapes exist and two
/// of them are searchable with one index:
///
/// * **No prefix.** The word starts at the position being searched, so the
///   first-four-bytes index finds it and the work is comparing the suffix after.
///   That covers `word + " "`, `word + "."`, `word + " the "` and the capitalised
///   spelling of each — the punctuation that follows most words in prose.
/// * **A prefix.** The text starts with those bytes and the word starts just past
///   them. The same index still works, one probe further in, and the prefix is
///   checked before the probe is worth making. That covers `" " + word`,
///   `" the " + word + " of "`, `"s " + word + " "` and the contraction spellings.
/// * **A kind that drops bytes** — omit last n, omit first n. The word is then
///   longer than the text it has to match, so the entry the index finds is not the
///   thing being compared. Left out.
///
/// That is 84 of the 121.
///
/// An affix does not have to keep the word's length. The copy length in the
/// command is the *word's* length — it selects the bucket — and the transform
/// decides how many bytes actually come out. So `time` with the "word and a space"
/// transform is a copy of four bytes that produces five.
const TRANSFORM_IDENTITY_ID : Int32 = 0

///|
const TRANSFORM_UPPERCASE_KIND : Int32 = 10

///|
/// One transform this writer can reach, with its affixes spelled out.
priv struct Affix {
  id : Int32
  prefix : Bytes
  suffix : Bytes
  capital : Bool
}

///|
/// The bytes of one prefix/suffix fragment.
fn fragment_bytes(id : Int32) -> Bytes {
  let at = prefix_suffix_map[id]
  let len = prefix_suffix[at].to_int()
  let out : Array[Byte] = []
  for i in 0..<len {
    out.push(prefix_suffix[at + 1 + i])
  }
  Bytes::from_array(out)
}

///|
/// The transforms this writer emits.
///
/// Kind zero is the plain transform and kind ten uppercases the first character;
/// the other kinds drop bytes from one end and are left out, because the word is
/// then longer than the text it has to match.
fn affix_table() -> Array[Affix] {
  let out : Array[Affix] = []
  for t in 0..<TRANSFORM_COUNT {
    let kind = transforms[t * 3 + 1]
    if kind == 0 || kind == TRANSFORM_UPPERCASE_KIND {
      out.push({
        id: t,
        prefix: fragment_bytes(transforms[t * 3]),
        suffix: fragment_bytes(transforms[t * 3 + 2]),
        capital: kind == TRANSFORM_UPPERCASE_KIND,
      })
    }
  }
  out
}

///|
/// A hash of four bytes, wrapping on purpose.
fn dict_key(b0 : Int32, b1 : Int32, b2 : Int32, b3 : Int32) -> Int32 {
  let h = (b0 * 0x1F1F1F1F) ^
    (b1 * 0x3B9ACA07) ^
    (b2 * 0x27D4EB2D) ^
    (b3 * 0x165667B1)
  h & 0xFFFF & ((1 << DICT_HASH_BITS) - 1)
}

///|
/// Lowercase one byte if it is a letter, which is what makes a sentence-initial
/// capital findable.
fn dict_lower(b : Int32) -> Int32 {
  if b >= 0x61 && b <= 0x7A {
    b
  } else if b >= 0x41 && b <= 0x5A {
    b + 32
  } else {
    b
  }
}

///|
/// Upper the same way, so a word's first letter can be checked against a capital
/// the text actually used.
fn dict_upper(b : Int32) -> Int32 {
  if b >= 0x61 && b <= 0x7A {
    b - 32
  } else {
    b
  }
}

///|
/// The dictionary, indexed for lookup by first four bytes.
priv struct DictIndex {
  heads : FixedArray[Int32]
  next : FixedArray[Int32]
  lens : FixedArray[Int32]
  slots : FixedArray[Int32]
  /// The three groups the search treats differently: no prefix and no capital, no
  /// prefix and a capital, and everything with a prefix.
  plain : Array[Affix]
  capital : Array[Affix]
  prefixed : Array[Affix]
}

///|
fn DictIndex::build() -> DictIndex {
  let mut words = 0
  for len in 4..<25 {
    words += 1 << dict_bits[len]
  }
  let heads = FixedArray::make(1 << DICT_HASH_BITS, -1)
  let next = FixedArray::make(words, -1)
  let lens = FixedArray::make(words, 0)
  let slots = FixedArray::make(words, 0)
  let mut ordinal = 0
  for len in 4..<25 {
    let count = 1 << dict_bits[len]
    for slot in 0..<count {
      let at = dict_offset[len] + slot * len
      let key = dict_key(
        dictionary[at].to_int(),
        dictionary[at + 1].to_int(),
        dictionary[at + 2].to_int(),
        dictionary[at + 3].to_int(),
      )
      next[ordinal] = heads[key]
      heads[key] = ordinal
      lens[ordinal] = len
      slots[ordinal] = slot
      ordinal += 1
    }
  }
  let plain : Array[Affix] = []
  let capital : Array[Affix] = []
  let prefixed : Array[Affix] = []
  for affix in affix_table() {
    if affix.prefix.length() > 0 {
      prefixed.push(affix)
    } else if affix.capital {
      capital.push(affix)
    } else {
      plain.push(affix)
    }
  }
  { heads, next, lens, slots, plain, capital, prefixed, }
}

///|
/// Does dictionary word `slot` of length `len` spell the input at `at`?
///
/// `capital` asks for the uppercase-first transform, which is the identity
/// compared byte for byte except that the first letter of the input has to be the
/// capital of the word's.
fn dict_spells(
  data : BytesView,
  at : Int32,
  len : Int32,
  slot : Int32,
  capital : Bool,
) -> Bool {
  let base = dict_offset[len] + slot * len
  for i in 0..<len {
    let word = dictionary[base + i].to_int()
    let seen = data[at + i].to_int()
    let want = if i == 0 && capital { dict_upper(word) } else { word }
    if seen != want {
      return false
    }
  }
  true
}

///|
/// Does `bytes` spell the input at `at`?
fn spells_at(data : BytesView, at : Int32, bytes : Bytes) -> Bool {
  for i in 0..<bytes.length() {
    if data[at + i] != bytes[i] {
      return false
    }
  }
  true
}

///|
/// The longest dictionary reference whose word starts at `wstart`.
///
/// Every affix in `group` shares the same word position, so the walk down the hash
/// chain happens once and the affixes only compete on their suffixes. `plen` is the
/// prefix length already accounted for before `wstart`, which is what makes the
/// returned length a count from the *original* position.
fn DictIndex::probe(
  self : DictIndex,
  data : BytesView,
  end : Int32,
  wstart : Int32,
  capital : Bool,
  group : Array[Affix],
  plen : Int32,
) -> (Int32, Int32, Int32, Int32) {
  let room = end - wstart
  if room < 4 {
    return (0, 0, 0, 0)
  }
  let first = data[wstart].to_int()
  let head = if capital { dict_lower(first) } else { first }
  let key = dict_key(
    head,
    data[wstart + 1].to_int(),
    data[wstart + 2].to_int(),
    data[wstart + 3].to_int(),
  )
  let mut best = 0
  let mut best_word = 0
  let mut best_slot = 0
  let mut best_transform = TRANSFORM_IDENTITY_ID
  let mut ordinal = self.heads[key]
  while ordinal >= 0 {
    let word_len = self.lens[ordinal]
    let slot = self.slots[ordinal]
    if word_len <= room && dict_spells(data, wstart, word_len, slot, capital) {
      for affix in group {
        let tail = word_len + affix.suffix.length()
        let taken = plen + tail
        if tail <= room &&
          taken > best &&
          spells_at(data, wstart + word_len, affix.suffix) {
          best = taken
          best_word = word_len
          best_slot = slot
          best_transform = affix.id
        }
      }
    }
    ordinal = self.next[ordinal]
  }
  (best, best_word, best_slot, best_transform)
}

///|
/// The longest dictionary reference starting at `at`, as
/// `(word length, bytes produced, slot, transform)`.
///
/// Word length is what the command carries — it selects the bucket — and bytes
/// produced is what the reader ends up appending, which is the same number only
/// when the transform adds nothing. A word length of zero means the dictionary has
/// nothing here, which is the answer for most positions and costs two hash probes.
///
/// The prefixed transforms are tried only when their prefix actually spells at the
/// position, which for most positions is a single byte comparison each and lets the
/// common case pay nothing for them.
fn DictIndex::find(
  self : DictIndex,
  data : BytesView,
  at : Int32,
  end : Int32,
) -> (Int32, Int32, Int32, Int32) {
  let room = end - at
  if room < 4 {
    return (0, 0, 0, 0)
  }
  let (t0, w0, s0, r0) = self.probe(data, end, at, false, self.plain, 0)
  let (t1, w1, s1, r1) = self.probe(data, end, at, true, self.capital, 0)
  let mut best = t0
  let mut best_word = w0
  let mut best_slot = s0
  let mut best_transform = r0
  if t1 > best {
    best = t1
    best_word = w1
    best_slot = s1
    best_transform = r1
  }
  for affix in self.prefixed {
    let plen = affix.prefix.length()
    if room < plen + 4 || !spells_at(data, at, affix.prefix) {
      continue
    }
    let one : Array[Affix] = [affix]
    let (t, w, s, r) = self.probe(
      data,
      end,
      at + plen,
      affix.capital,
      one,
      plen,
    )
    if t > best {
      best = t
      best_word = w
      best_slot = s
      best_transform = r
    }
  }
  (best_word, best, best_slot, best_transform)
}

///|
/// The address a dictionary reference carries: the transform above the bits that
/// select the word, which is the inverse of what `dictionary_word` reads.
fn DictIndex::address(len : Int32, slot : Int32, transform : Int32) -> Int32 {
  (transform << dict_bits[len]) | slot
}
