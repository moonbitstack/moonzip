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
/// The transforms this writer reaches: 103 of the 121.
///
/// Every transform is a prefix, a kind, and a suffix, and the kind decides how the
/// word is bent: nothing, uppercase the first character, uppercase everything, or
/// drop n characters off one end.
///
/// * **No prefix.** The word starts at the position being searched, so the
///   first-four-bytes index finds it and the work is comparing what follows. That
///   covers `word + " "`, `word + "."`, `word + " the "` and the capitalised and
///   shouted spellings of each — the punctuation that follows most words in prose.
/// * **A prefix.** The text starts with those bytes and the word starts just past
///   them, so the same index still works, one probe further in. That covers
///   `" " + word`, `" the " + word + " of "` and the contraction spellings.
///
/// Two families are left out, for two different reasons.
///
/// * **Dropping the first n bytes** — eight transforms. The word's opening bytes
///   are exactly what the text does not contain, so the index has no key to offer;
///   reaching them means a second index over every word at each of eight offsets,
///   nine thousand extra entries and a megabyte of tables.
/// * **Dropping the last n bytes** — ten transforms. These *are* reachable: the
///   text still starts with the word's first bytes, only fewer of them, so the same
///   chain walk applies. But the writer declines them, because a length-greedy
///   parser cannot use them profitably. A truncated word covers less text than the
///   word it names, and the reference costs the same far distance either way. On
///   this repository's own documentation they fire 578 times at a four-byte
///   minimum and make the output 260 bytes *larger*; raising the minimum to six,
///   eight and ten bytes shrinks how often they fire and never turns the sign
///   round. They are in the format for languages whose words are built out of other
///   words; an English prose file is not that, and the encoder says so rather than
///   paying for them.
///
/// An affix does not have to keep the word's length: the copy length in the command
/// is the *word's* length, because that is what selects the bucket, and the
/// transform decides how many bytes come out. So `time` with the "word and a
/// space" transform is a copy of four bytes that produces five.
const TRANSFORM_IDENTITY_ID : Int32 = 0

///|
const TRANSFORM_UPPERCASE_KIND : Int32 = 10

///|
const TRANSFORM_UPPERCASE_ALL_KIND : Int32 = 11

///|
/// A word is compared against the text in one of three cases, and each needs its
/// own probe because the hash is taken over the text's bytes.
const CASE_PLAIN : Int32 = 0

///|
const CASE_FIRST : Int32 = 1

///|
const CASE_ALL : Int32 = 2

///|
/// One transform this writer can reach, with its affixes spelled out.
priv struct Affix {
  id : Int32
  prefix : Bytes
  suffix : Bytes
  mode : Int32
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
/// Kinds twelve to twenty drop bytes off the *front* of the word and are left out;
/// everything else is here, with `omit last n` recorded as a drop of n.
fn affix_table() -> Array[Affix] {
  let out : Array[Affix] = []
  for t in 0..<TRANSFORM_COUNT {
    let kind = transforms[t * 3 + 1]
    let mut mode = CASE_PLAIN
    let mut take = true
    if kind == TRANSFORM_UPPERCASE_KIND {
      mode = CASE_FIRST
    } else if kind == TRANSFORM_UPPERCASE_ALL_KIND {
      mode = CASE_ALL
    } else if kind != 0 {
      take = false
    }
    if take {
      out.push({
        id: t,
        prefix: fragment_bytes(transforms[t * 3]),
        suffix: fragment_bytes(transforms[t * 3 + 2]),
        mode,
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
/// The dictionary, indexed for lookup by first four bytes.
priv struct DictIndex {
  heads : FixedArray[Int32]
  next : FixedArray[Int32]
  lens : FixedArray[Int32]
  slots : FixedArray[Int32]
  /// The groups the search treats differently: one per case with no prefix, and
  /// everything with a prefix, where each affix carries its own case.
  plain : Array[Affix]
  first : Array[Affix]
  all : Array[Affix]
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
  let first : Array[Affix] = []
  let all : Array[Affix] = []
  let prefixed : Array[Affix] = []
  for affix in affix_table() {
    if affix.prefix.length() > 0 {
      prefixed.push(affix)
    } else if affix.mode == CASE_FIRST {
      first.push(affix)
    } else if affix.mode == CASE_ALL {
      all.push(affix)
    } else {
      plain.push(affix)
    }
  }
  { heads, next, lens, slots, plain, first, all, prefixed, }
}

///|
/// Highercase one byte the way the reader does, or the byte unchanged.
///
/// The reader's rule flips bit five of a lowercase letter and, for a byte that
/// starts a multi-byte character, bit five of the *following* byte instead. The
/// writer only claims a capitalised or shouted match when every byte involved is
/// below 0xC0, where the rule is this one — so the comparison below never has to
/// model the multi-byte case, and the two sides cannot disagree.
fn dict_upper(b : Int32) -> Int32 {
  if b >= 0x61 && b <= 0x7A {
    b - 32
  } else {
    b
  }
}

///|
/// Does dictionary word `slot` of length `len` spell the input at `at`, under a
/// transform that cases it?
///
/// A byte at or above 0xC0 is the start of a multi-byte character, where the
/// reader's uppercase rule touches the byte *after* it and this comparison cannot
/// follow. Such a word is refused rather than guessed at.
fn dict_spells_mode(
  data : BytesView,
  at : Int32,
  len : Int32,
  slot : Int32,
  mode : Int32,
) -> Bool {
  let base = dict_offset[len] + slot * len
  for i in 0..<len {
    let word = dictionary[base + i].to_int()
    let want = if mode == CASE_PLAIN {
      word
    } else if mode == CASE_FIRST {
      if i == 0 {
        if word >= 0xC0 {
          return false
        }
        dict_upper(word)
      } else {
        word
      }
    } else if word >= 0xC0 {
      return false
    } else {
      dict_upper(word)
    }
    if data[at + i].to_int() != want {
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
/// Every affix in `group` shares the same word position and case, so the walk down
/// the hash chain happens once and the affixes compete only on how much of the
/// word they keep. `plen` is the prefix length already accounted for, which is what
/// makes the returned length a count from the *original* position.
fn DictIndex::probe(
  self : DictIndex,
  data : BytesView,
  end : Int32,
  wstart : Int32,
  mode : Int32,
  group : Array[Affix],
  plen : Int32,
) -> (Int32, Int32, Int32, Int32) {
  let room = end - wstart
  if room < 4 {
    return (0, 0, 0, 0)
  }
  let b0 = data[wstart].to_int()
  let b1 = data[wstart + 1].to_int()
  let b2 = data[wstart + 2].to_int()
  let b3 = data[wstart + 3].to_int()
  let head = if mode == CASE_PLAIN { b0 } else { dict_lower(b0) }
  let key = if mode == CASE_ALL {
    dict_key(dict_lower(head), dict_lower(b1), dict_lower(b2), dict_lower(b3))
  } else {
    dict_key(head, b1, b2, b3)
  }
  let mut best = 0
  let mut best_word = 0
  let mut best_slot = 0
  let mut best_transform = TRANSFORM_IDENTITY_ID
  let mut ordinal = self.heads[key]
  while ordinal >= 0 {
    let word_len = self.lens[ordinal]
    let slot = self.slots[ordinal]
    // The whole word first: it is the longest a transform can produce, so once it
    // matches, only the affixes that keep all of it can win.
    if word_len <= room && dict_spells_mode(data, wstart, word_len, slot, mode) {
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
/// when the transform adds or drops nothing. A word length of zero means the
/// dictionary has nothing here, which is the answer for most positions.
///
/// A prefixed transform is tried only when its prefix actually spells at the
/// position, which for most positions is a single byte comparison each and lets
/// the common case pay nothing for them.
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
  let (t0, w0, s0, r0) = self.probe(data, end, at, CASE_PLAIN, self.plain, 0)
  let (t1, w1, s1, r1) = self.probe(data, end, at, CASE_FIRST, self.first, 0)
  let (t2, w2, s2, r2) = self.probe(data, end, at, CASE_ALL, self.all, 0)
  let mut best = t0
  let mut best_word = w0
  let mut best_slot = s0
  let mut best_transform = r0
  for other in [(t1, w1, s1, r1), (t2, w2, s2, r2)] {
    let (t, w, s, r) = other
    if t > best {
      best = t
      best_word = w
      best_slot = s
      best_transform = r
    }
  }
  for affix in self.prefixed {
    let plen = affix.prefix.length()
    if room < plen + 4 || !spells_at(data, at, affix.prefix) {
      continue
    }
    let one : Array[Affix] = [affix]
    let (t, w, s, r) = self.probe(data, end, at + plen, affix.mode, one, plen)
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
