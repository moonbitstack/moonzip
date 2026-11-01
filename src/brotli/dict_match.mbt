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
/// The transforms this writer emits: the ones whose prefix is empty.
///
/// The format has 121 and most of them are affix surgery. A transform with a
/// prefix puts bytes *before* the word, so the text at the position no longer
/// begins with the word — the index, which is built on the word's own first four
/// bytes, cannot find it, and searching for it would need a second index over
/// prefixed spellings. A transform with an empty prefix leaves the word at the
/// front of the text, so the same probe finds it and the suffix is only a
/// comparison of a few bytes after it. That is the cut this writer makes: fifty
/// four transforms, including `word + " "`, `word + "."`, `word + ", "` and the
/// capitalised spellings of each, which between them cover the punctuation that
/// follows most words in prose.
///
/// A transform's affix does not have to keep the word's length. The copy length
/// in the command is the *word's* length — it selects the bucket — and the
/// transform decides how many bytes actually come out. So `time` with the
/// "word and a space" transform is a copy of four bytes that produces five.
const TRANSFORM_IDENTITY_ID : Int32 = 0

///|
const TRANSFORM_UPPERCASE_KIND : Int32 = 10

///|

///|
/// One transform this writer can reach, with its suffix spelled out.
priv struct Affix {
  id : Int32
  suffix : Bytes
  capital : Bool
}

///|
/// Is this fragment id the empty fragment?
fn fragment_is_empty(id : Int32) -> Bool {
  prefix_suffix[prefix_suffix_map[id]].to_int() == 0
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
/// The transforms whose prefix is empty and whose kind only appends a suffix.
///
/// Kind zero is the plain transform and kind ten uppercases the first character;
/// the other kinds drop bytes from one end, which would make the word longer than
/// the text it has to match and is left out here.
fn affix_table() -> Array[Affix] {
  let out : Array[Affix] = []
  for t in 0..<TRANSFORM_COUNT {
    let kind = transforms[t * 3 + 1]
    if (kind == 0 || kind == TRANSFORM_UPPERCASE_KIND) &&
      fragment_is_empty(transforms[t * 3]) {
      out.push({
        id: t,
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
  affixes : Array[Affix]
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
  { heads, next, lens, slots, affixes: affix_table(), }
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
/// Does `suffix` spell the input just past `at`?
fn suffix_spells(data : BytesView, at : Int32, suffix : Bytes) -> Bool {
  for i in 0..<suffix.length() {
    if data[at + i] != suffix[i] {
      return false
    }
  }
  true
}

///|
/// The longest dictionary reference starting at `at`, as
/// `(word length, bytes produced, slot, transform)`.
///
/// Word length is what the command carries — it selects the bucket — and bytes
/// produced is what the reader ends up appending, which is the same number only
/// when the transform adds nothing. A word length of zero means the dictionary has
/// nothing here, which is the answer for most positions and costs one hash probe.
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
  let first = data[at].to_int()
  let second = data[at + 1].to_int()
  let third = data[at + 2].to_int()
  let fourth = data[at + 3].to_int()
  let mut best = 0
  let mut best_word = 0
  let mut best_slot = 0
  let mut best_transform = TRANSFORM_IDENTITY_ID
  let mut probe = 0
  while probe < 2 {
    let head = if probe == 0 { first } else { dict_lower(first) }
    // The second probe is skipped when the first byte has no case — then it would
    // repeat the first probe — and it only looks for the capitalised transforms.
    if probe == 0 || head != first {
      let capital = probe == 1
      let mut ordinal = self.heads[dict_key(head, second, third, fourth)]
      while ordinal >= 0 {
        let word_len = self.lens[ordinal]
        // A longer transform on the word already found can only win if the word
        // itself did, so a word shorter than the best is not worth checking.
        if word_len <= room &&
          dict_spells(data, at, word_len, self.slots[ordinal], capital) {
          let slot = self.slots[ordinal]
          for affix in self.affixes {
            if affix.capital == capital {
              let taken = word_len + affix.suffix.length()
              if taken > best &&
                taken <= room &&
                suffix_spells(data, at + word_len, affix.suffix) {
                best = taken
                best_word = word_len
                best_slot = slot
                best_transform = affix.id
              }
            }
          }
        }
        ordinal = self.next[ordinal]
      }
    }
    probe += 1
  }
  (best_word, best, best_slot, best_transform)
}

///|
/// The address a dictionary reference carries: the transform above the bits that
/// select the word, which is the inverse of what `dictionary_word` reads.
fn DictIndex::address(len : Int32, slot : Int32, transform : Int32) -> Int32 {
  (transform << dict_bits[len]) | slot
}
